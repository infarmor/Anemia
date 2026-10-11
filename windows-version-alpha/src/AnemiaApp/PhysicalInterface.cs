using System.Net.NetworkInformation;

namespace AnemiaApp;

/// <summary>
/// Windows port of the macOS PhysicalInterface probe: finds the name of the
/// active physical uplink (Ethernet / Wi-Fi), used to pin the engine's
/// outbound socket to the real interface so a system-route-level tunnel can
/// never capture the engine's own traffic (a routing loop).
/// Returns null when no physical uplink is up — the builder then leaves
/// <c>sockopt.dialerInterface</c> unset rather than pinning to garbage.
/// </summary>
public static class PhysicalInterface
{
    public static string? Detect()
    {
        try
        {
            var candidates = NetworkInterface.GetAllNetworkInterfaces()
                .Where(n => n.OperationalStatus == OperationalStatus.Up)
                .Where(n => n.NetworkInterfaceType is NetworkInterfaceType.Ethernet
                    or NetworkInterfaceType.Wireless80211)
                // Virtual adapters that host the tunnel itself (and hypervisor
                // fabrics) must never be picked as the "physical" uplink.
                .Where(n =>
                {
                    var id = n.Id ?? "";
                    var desc = n.Description ?? "";
                    var name = n.Name ?? "";
                    return !desc.Contains("Virtual", StringComparison.OrdinalIgnoreCase)
                        && !desc.Contains("Hyper-V", StringComparison.OrdinalIgnoreCase)
                        && !desc.Contains("VMware", StringComparison.OrdinalIgnoreCase)
                        && !desc.Contains("VirtualBox", StringComparison.OrdinalIgnoreCase)
                        && !name.Contains("wintun", StringComparison.OrdinalIgnoreCase)
                        && !name.Contains("Anemia", StringComparison.OrdinalIgnoreCase)
                        && !id.Contains("tun", StringComparison.OrdinalIgnoreCase);
                })
                .OrderBy(n => n.NetworkInterfaceType == NetworkInterfaceType.Ethernet ? 0 : 1)
                .ToList();
            return candidates.Count == 0 ? null : candidates[0].Name;
        }
        catch (NetworkInformationException)
        {
            return null;
        }
    }
}