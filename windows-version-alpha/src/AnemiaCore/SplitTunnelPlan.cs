using System.Globalization;

namespace AnemiaCore;

/// <summary>
/// Which routes keep the user's bypass destinations off the tunnel, in what
/// order the helper puts them there, and what it may never route. The Windows
/// shape of the split-tunnel state machine in
/// <c>Sources/LoaderHelper/HelperService.swift</c>: each rule here has a line
/// in that file it mirrors.
///
/// The system stays out of it: the helper answers for the gateways, the on-link
/// prefixes and the DNS results, so the whole decision — caps, dedup, the ranges
/// that must never be bypassed, what survives a mid-session rule change — is
/// testable without a route table. What cannot be measured away from Windows is
/// only the spelling of the rendered <c>route.exe</c> arguments, which lives in
/// exactly one function for that reason.
/// </summary>
public static class SplitTunnelPlan
{
    /// <summary>macOS caps: 256 networks per family, 64 domains, 256 hosts per
    /// family. Not a nicety — one domain behind a CDN answers dozens of
    /// addresses every time it is re-resolved, and the list grows.</summary>
    public const int NetworkCap = 256;
    public const int DomainCap = 64;
    public const int HostCap = 256;

    public static readonly string TunnelOverlapReason = "that range is the VPN tunnel itself";

    public enum Action { Add, Change, Delete }

    /// <summary>An address with a prefix length, as the helper reads it off the
    /// adapters (<c>192.168.1.0</c>/24) and as the parser normalizes a bypass
    /// line to.</summary>
    public readonly record struct Prefix(string Address, int Bits, bool IsIPv6);

    /// <summary>One route table entry this helper owns.</summary>
    public readonly record struct Route(string Destination, int Bits, bool IsNetwork, bool IsIPv6)
    {
        /// <summary>IPv4 wants a dotted netmask, IPv6 a prefix length — the two
        /// forms <c>route.exe</c> takes after <c>mask</c>.</summary>
        public string MaskText => IsIPv6
            ? Bits.ToString(CultureInfo.InvariantCulture)
            : MaskFromBits(Bits);

        public Prefix AsPrefix() => new(Destination, Bits, IsIPv6);
    }

    /// <summary>A single <c>route.exe</c> invocation, decided.</summary>
    public readonly record struct Operation(Action What, Route Route, string? Gateway, int? InterfaceIndex)
    {
        /// <summary>Arguments for <c>route.exe</c>. The IPv6 spelling (<c>-6</c>
        /// before the verb, prefix length as the mask) and the fact that a
        /// link-local v6 gateway needs <c>if</c> are documented, not measured
        /// here — this is the one place a Windows reading has to correct.</summary>
        public string Arguments
        {
            get
            {
                var family = Route.IsIPv6 ? "-6 " : "";
                var body = What switch
                {
                    Action.Delete => $"delete {Route.Destination} mask {Route.MaskText}",
                    _ => $"{(What == Action.Change ? "change" : "add")} {Route.Destination} " +
                         $"mask {Route.MaskText} {Gateway}"
                };
                // An interface index is only worth appending when the gateway
                // does not already name one: without it a multi-homed machine
                // resolves a fe80:: next hop to no interface at all.
                if (What != Action.Delete && InterfaceIndex is { } index)
                    body += $" if {index.ToString(CultureInfo.InvariantCulture)}";
                return family + body;
            }
        }
    }

    /// <summary>What the OS says right now. Built by the helper before each
    /// planning call.</summary>
    public sealed class Env
    {
        public string? GatewayV4 { get; init; }
        public string? GatewayV6 { get; init; }
        public int? InterfaceV4 { get; init; }
        public int? InterfaceV6 { get; init; }

        /// <summary>Prefixes of the physical adapters: routing those is the
        /// link's own business, and repointing them would cut the LAN.</summary>
        public List<Prefix> OnLink { get; init; } = new();

        /// <summary>Ranges the tunnel itself lives in. A bypass overlapping one
        /// would take away the tunnel's own address space.</summary>
        public List<Prefix> TunnelOwned { get; init; } = new();

        /// <summary>Host routes the engine's server pin already owns. The
        /// session's bypass must not replace them.</summary>
        public List<string> ServerPinsV4 { get; init; } = new();
        public List<string> ServerPinsV6 { get; init; } = new();
    }

    /// <summary>What the helper has installed for this session. Mutable: the
    /// calls below update it as they emit operations, so a caller that has run
    /// one of them can trust it to describe the table.</summary>
    public sealed class State
    {
        public List<string> NetworksV4 { get; } = new();
        public List<string> NetworksV6 { get; } = new();
        public List<string> Domains { get; } = new();
        public List<string> HostsV4 { get; } = new();
        public List<string> HostsV6 { get; } = new();
        public List<Route> Installed { get; } = new();

        public bool Empty => NetworksV4.Count == 0 && NetworksV6.Count == 0 &&
                             Domains.Count == 0 && HostsV4.Count == 0 && HostsV6.Count == 0;

        public void Clear()
        {
            NetworksV4.Clear();
            NetworksV6.Clear();
            Domains.Clear();
            HostsV4.Clear();
            HostsV6.Clear();
            Installed.Clear();
        }
    }

    public readonly record struct Result(List<Operation> Operations, List<string> Problems, bool Grew);

    /// <summary>
    /// Replace the session's rules with the lines the client sends. Everything
    /// the helper owns comes down first, so a destination the user just removed
    /// stops being bypassed — then the new list is validated here, because the
    /// client is not privileged and must not get to name the default route.
    /// </summary>
    public static Result Apply(State state, Env env, IEnumerable<string> lines,
                               Func<string, List<string>> resolveV4,
                               Func<string, List<string>>? resolveV6 = null)
    {
        var ops = new List<Operation>();
        var problems = new List<string>();

        var parsed = SplitTunnelParser.Parse(lines);
        foreach (var rejection in parsed.Rejected)
            problems.Add($"{rejection.Line}: {rejection.Reason}");

        // Whatever was up before this call stops existing.
        foreach (var route in state.Installed)
            ops.Add(new Operation(Action.Delete, route, null, null));
        state.Clear();

        foreach (var entry in parsed.Entries)
        {
            if (entry.EntryKind != BypassEntry.Kind.Domain &&
                OverlapsTunnel(CidrRoute(entry.Value, entry.EntryKind == BypassEntry.Kind.IPv6, true).AsPrefix(), env))
            {
                // Refused at the helper rather than the parser: the ranges are
                // ours to know and differ per platform, while the parser is
                // pinned to what Swift and Kotlin accept for the same text.
                problems.Add($"{entry.Value}: {TunnelOverlapReason}");
                continue;
            }
            switch (entry.EntryKind)
            {
                case BypassEntry.Kind.IPv4 when state.NetworksV4.Count < NetworkCap:
                    state.NetworksV4.Add(entry.Value);
                    break;
                case BypassEntry.Kind.IPv6 when state.NetworksV6.Count < NetworkCap:
                    state.NetworksV6.Add(entry.Value);
                    break;
                case BypassEntry.Kind.Domain when state.Domains.Count < DomainCap:
                    state.Domains.Add(entry.Value);
                    break;
                default:
                    break;      // over the cap: dropped, as on macOS
            }
        }

        if (!state.Empty && env.GatewayV4 is null)
        {
            problems.Add("no physical gateway");
            return new Result(ops, problems, false);
        }

        ResolveHosts(state, env, resolveV4, resolveV6, out _);
        InstallAll(state, env, ops, problems);
        return new Result(ops, problems, false);
    }

    /// <summary>
    /// Re-pin what is already installed and pick up addresses the domains have
    /// gained — after a gateway change, or on the heartbeat. Nothing is deleted:
    /// a route that goes away mid-session cuts the connection riding on it, and
    /// macOS keeps known hosts for exactly that reason.
    /// </summary>
    public static Result Reassert(State state, Env env,
                                  Func<string, List<string>> resolveV4,
                                  Func<string, List<string>>? resolveV6 = null)
    {
        if (state.Empty) return new Result(new List<Operation>(), new List<string>(), false);
        // Without a gateway there is nothing to re-pin to, and no user to tell:
        // the rules are already recorded and will install with the next tunnel.
        if (env.GatewayV4 is null) return new Result(new List<Operation>(), new List<string>(), false);

        var problems = new List<string>();
        var ops = new List<Operation>();
        ResolveHosts(state, env, resolveV4, resolveV6, out var grew);
        InstallAll(state, env, ops, problems);
        return new Result(ops, problems, grew);
    }

    /// <summary>Delete every route this session installed and forget the lists.</summary>
    public static List<Operation> TearDown(State state)
    {
        var ops = state.Installed.Select(route => new Operation(Action.Delete, route, null, null)).ToList();
        state.Clear();
        return ops;
    }

    /// <summary>
    /// The addresses a kill switch must keep dialable for the bypass to work at
    /// all: sealed egress plus a route to the physical gateway is a destination
    /// that resolves and never connects. macOS builds the same list as
    /// <c>bypass + networks + hosts</c>, hosts that are not already pins first.
    /// </summary>
    public static (List<string> V4, List<string> V6) AllowList(State state, Env env)
    {
        var v4 = new List<string>(env.ServerPinsV4);
        foreach (var item in state.NetworksV4.Concat(state.HostsV4))
            if (!v4.Contains(item)) v4.Add(item);
        var v6 = new List<string>(env.ServerPinsV6);
        foreach (var item in state.NetworksV6.Concat(state.HostsV6))
            if (!v6.Contains(item)) v6.Add(item);
        return (v4, v6);
    }

    // MARK: - Steps

    private static void InstallAll(State state, Env env, List<Operation> ops, List<string> problems)
    {
        foreach (var network in state.NetworksV4)
            Pin(state, env, ops, problems, CidrRoute(network, false, true));
        foreach (var host in state.HostsV4)
            if (!env.ServerPinsV4.Contains(host))
                Pin(state, env, ops, problems, HostRoute(host, false));
        if (env.GatewayV6 is not null)
        {
            foreach (var network in state.NetworksV6)
                Pin(state, env, ops, problems, CidrRoute(network, true, true));
            foreach (var host in state.HostsV6)
                if (!env.ServerPinsV6.Contains(host))
                    Pin(state, env, ops, problems, HostRoute(host, true));
        }
    }

    /// <summary>macOS pins in this order: v4 networks, v4 hosts, then the v6
    /// pair — and only when there is an IPv6 gateway, which most machines have
    /// not. A v6 destination without one is left unrouted in silence there, so
    /// it is left unrouted here too: telling the user about a thing every
    /// v4-only network does is noise that hides the rejections that matter.</summary>
    private static void Pin(State state, Env env, List<Operation> ops, List<string> problems, Route route)
    {
        var known = state.Installed.Any(r =>
            r.Destination == route.Destination && r.IsIPv6 == route.IsIPv6);
        // Only a route we have not put there yet is worth a lookup: ours is by
        // definition not on-link, and asking again would re-read the table for
        // every destination on every heartbeat.
        if (!known && IsDirectlyConnected(route, env)) return;

        var gateway = route.IsIPv6 ? env.GatewayV6 : env.GatewayV4;
        if (gateway is null) return;
        var index = route.IsIPv6 ? env.InterfaceV6 : env.InterfaceV4;
        // A known entry is re-pinned with `change`: the gateway it was added
        // through may no longer exist, and adding over an existing route is
        // what makes the whole sequence non-idempotent.
        ops.Add(new Operation(known ? Action.Change : Action.Add, route, gateway, index));
        if (!known) state.Installed.Add(route);
    }

    /// <summary>Addresses the domains stand for, appended to what is already
    /// routed. Fake-IP answers are dropped: a concurrent fake-IP client answers
    /// the system resolver from the tunnel's own pool, and a route to a pool
    /// address is a route to nothing.</summary>
    private static void ResolveHosts(State state, Env env,
                                     Func<string, List<string>> resolveV4,
                                     Func<string, List<string>>? resolveV6,
                                     out bool grew)
    {
        grew = false;
        foreach (var name in state.Domains)
        {
            foreach (var ip in resolveV4(name))
            {
                if (DirectResolver.IsFakeIP(ip) || state.HostsV4.Contains(ip) ||
                    state.HostsV4.Count >= HostCap) continue;
                state.HostsV4.Add(ip);
                grew = true;
            }
            if (env.GatewayV6 is null || resolveV6 is null) continue;
            foreach (var ip in resolveV6(name))
            {
                if (state.HostsV6.Contains(ip) || state.HostsV6.Count >= HostCap) continue;
                state.HostsV6.Add(ip);
                grew = true;
            }
        }
    }

    // MARK: - Prefix arithmetic

    private static bool OverlapsTunnel(Prefix candidate, Env env) =>
        env.TunnelOwned.Any(owned => Covers(owned, candidate) || Covers(candidate, owned));

    /// <summary>Whether every address inside <c>inner</c> is also inside
    /// <c>outer</c>. Two CIDR blocks either nest or are disjoint, so this also
    /// answers "do they overlap at all" when tried both ways.</summary>
    public static bool Covers(Prefix outer, Prefix inner)
    {
        if (outer.IsIPv6 != inner.IsIPv6) return false;
        if (outer.Bits > inner.Bits) return false;
        if (!TryBytes(outer.Address, outer.IsIPv6, out var outerBytes)) return false;
        if (!TryBytes(inner.Address, inner.IsIPv6, out var innerBytes)) return false;
        for (var bit = 0; bit < outer.Bits; bit++)
        {
            var mask = (byte)(0x80 >> (bit % 8));
            if ((outerBytes[bit / 8] & mask) != (innerBytes[bit / 8] & mask)) return false;
        }
        return true;
    }

    /// <summary>Whether the destination already leaves through a link, with no
    /// gateway to send it to. Such a destination is off the tunnel whatever the
    /// tunnel does with the default route, and pointing its link route at a
    /// gateway would take the LAN down a different path.</summary>
    private static bool IsDirectlyConnected(Route route, Env env) =>
        env.OnLink.Any(link => Covers(link, route.AsPrefix()));

    /// <summary>Four octets or sixteen bytes, strictly: a destination the parser
    /// accepted is one of these two shapes, and anything else says so rather
    /// than being read as zeroes.</summary>
    private static bool TryBytes(string text, bool isIPv6, out byte[] bytes)
    {
        bytes = Array.Empty<byte>();
        if (isIPv6)
        {
            if (!Inet6.Pton(text, out var six)) return false;
            bytes = six;
            return true;
        }
        var parts = text.Split('.', StringSplitOptions.None);
        if (parts.Length != 4 || !parts.All(p => p.Length is > 0 and <= 3 && p.All(c => c is >= '0' and <= '9')))
            return false;
        var value = 0u;
        foreach (var part in parts)
        {
            var octet = uint.Parse(part, CultureInfo.InvariantCulture);
            if (octet > 255) return false;
            value = value << 8 | octet;
        }
        bytes = new[] { (byte)(value >> 24), (byte)(value >> 16), (byte)(value >> 8), (byte)value };
        return true;
    }

    private static Route CidrRoute(string cidr, bool isIPv6, bool isNetwork)
    {
        var slash = cidr.LastIndexOf('/');
        var bits = slash >= 0 ? ParseBits(cidr[(slash + 1)..]) : (isIPv6 ? 128 : 32);
        return new Route(slash >= 0 ? cidr[..slash] : cidr, bits ?? (isIPv6 ? 128 : 32), isNetwork, isIPv6);
    }

    private static Route HostRoute(string address, bool isIPv6) =>
        new(address, isIPv6 ? 128 : 32, false, isIPv6);

    private static int? ParseBits(string text) =>
        text.Length is > 0 and < 4 && text.All(c => c is >= '0' and <= '9')
            ? int.Parse(text, CultureInfo.InvariantCulture)
            : null;

    /// <summary>Dotted netmask for a prefix length. Only called for IPv4.</summary>
    public static string MaskFromBits(int bits)
    {
        var mask = bits == 0 ? 0u : uint.MaxValue << (32 - bits);
        return string.Join('.', new[] { 24, 16, 8, 0 }
            .Select(shift => ((mask >> shift) & 0xFF).ToString(CultureInfo.InvariantCulture)));
    }

    /// <summary>Parse a CIDR string the helper read off an adapter into a
    /// <see cref="Prefix"/>. Strict enough that garbage yields null rather than
    /// a prefix that silently covers nothing.</summary>
    public static bool TryPrefix(string cidr, out Prefix prefix)
    {
        prefix = default;
        var slash = cidr.LastIndexOf('/');
        if (slash <= 0) return false;
        var bits = ParseBits(cidr[(slash + 1)..]);
        if (bits is null) return false;
        var address = cidr[..slash];
        var isIPv6 = address.Contains(':');
        if (bits > (isIPv6 ? 128 : 32)) return false;
        if (!TryBytes(address, isIPv6, out _)) return false;
        prefix = new Prefix(address, (int)bits, isIPv6);
        return true;
    }
}
