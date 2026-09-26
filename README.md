# Anemia (macOS)

VPN client for macOS that bypasses network blocking by wrapping the
**Xray-core** engine (plus AmneziaWG and Hysteria 2 engines). Traffic is made
unreadable and hard to fingerprint using Xray's native anti-DPI features —
Reality/XTLS-Vision, TLS ClientHello fragmentation, and junk-noise packets —
while staying fast on Apple Silicon.

> Legitimate censorship-circumvention / privacy tool. You are responsible for
> complying with the laws that apply to you.

## Architecture

```
┌──────────────────────────────────────────────┐
│ LoaderApp  (SwiftUI window + menu bar)        │
│  • import vless/vmess/ss/trojan/hy2/awg links │
│  • XrayConfigBuilder → xray-core JSON          │
│  • XrayController: spawns `xray run -c cfg`     │
│  • NetworkHealthScan: finds broken leftovers    │
│  • HelperClient: XPC → privileged helper        │
└───────────────┬───────────────┬────────────────┘
                │ SOCKS/HTTP     │ XPC (code-signature verified)
                ▼                ▼
        127.0.0.1:10808   ┌──────────────────────────────┐
        (xray inbounds)   │ LoaderHelper (root daemon)    │
                          │  • utun + split routes         │
                          │  • tun2socks / amneziawg-go    │
                          │  • pf kill switch (own anchor) │
                          │  • DNS / proxy via the journal │
                          └──────────────────────────────┘
```

* **LoaderCore** — pure, unit-tested logic: share-link/subscription parsing and
  engine config generation (incl. anti-DPI). No UI, no root.
* **LoaderShared** — the XPC contract, the helper's LaunchDaemon definition and
  the network-safety policy shared by app and helper.
* **LoaderApp** — the client.
* **LoaderHelper** — privileged helper: utun, routing, bridge supervision, kill
  switch, and every persistent system change.

## Network safety

A VPN client must never leave a Mac offline — not after a crash, a force-quit,
a power loss or an uninstall. The helper (0.8.0+) guarantees it:

* **Journal before change.** System DNS and SOCKS proxy settings survive
  reboots, so every change is recorded — fsync'd — in
  `/var/db/Loader/network-journal.json` *before* it is made. Our own values
  (tunnel resolvers, engine proxy ports) are never recorded as the user's
  settings, VPN services of other clients are never touched, and an entry is
  dropped only after its restore verifiably landed.
* **Recovery at every launch.** The daemon starts at boot (`RunAtLoad`) and is
  respawned after a crash (`KeepAlive` → `SuccessfulExit=false`); each launch
  replays the journal, flushes the kill switch, kills orphaned bridges, drops
  dead routes and resets resolvers pinned to tunnels that no longer exist.
* **Kill switch in its own pf anchor** (`com.apple/000.AnemiaKillSwitch`): the
  main ruleset is never replaced, disarming is flushing one anchor, and the
  rules are validated by the real `pfctl` parser in the tests.
* **Watchdog + graceful SIGTERM.** A proxy pointing at a dead port or a
  resolver override without a tunnel is restored within 15 s; `launchctl
  bootout` / shutdown runs the full teardown.
* **Repair, with or without the helper.** Settings → Network safety → *Repair*
  (the main window and menu bar offer it automatically when the scan finds a
  broken leftover), or from Terminal:

  ```bash
  sudo bash Scripts/anemia-network-reset.sh
  ```

Details (in Russian): [Docs/network-recovery.md](Docs/network-recovery.md).

## Split tunneling (local bypass)

Settings → Split tunneling: networks and domains listed there use the regular
connection instead of the VPN — a local bank or government site that refuses
foreign IPs, a work network, a NAS on another subnet. One entry per line (or
pasted comma-separated):

```
10.8.0.0/16          # IPv4 network (host bits are cleared)
203.0.113.7          # single address
2001:db8::/32        # IPv6
bank.ru              # domain — subdomains included (*.bank.ru works too)
сбербанк.рф          # IDN, converted to punycode
```

It works on two levels, so it holds in every mode:

* **System tunnel (helper):** networks, and the current addresses of listed
  domains, are routed via the physical gateway — that traffic never enters the
  utun — and stay open under the kill switch. Domains are re-resolved on the
  60 s heartbeat and after network changes. Destinations on a directly
  connected link are left alone. The routes live in the kernel for the session
  only and are removed on disconnect.
* **Engine (Xray):** matching connections go to a `bypass` freedom outbound
  pinned to the physical interface — covering proxy-mode traffic and addresses
  a domain rotated to since. Without a detected physical interface the rules
  are omitted (an unpinned direct dial would loop back into the tunnel).

Entries that would defeat the VPN are rejected with a reason: IPv4 prefixes
shorter than /8 (IPv6 /16), loopback, and the tunnel's own ranges. The helper
re-validates every entry it receives. Changes apply on the next connect.

### Anti-DPI ("junk") mapping

| Requirement                | Xray feature                              |
|----------------------------|-------------------------------------------|
| Traffic can't be read      | VLESS + **Reality** + **XTLS-Vision** (TLS 1.3, real-site handshake mimicry) |
| Protect with junk          | `sockopt.noises` (junk packets) + `fragment` (ClientHello shredding) |
| Fast                       | XTLS-Vision splice, uTLS `chrome` fingerprint, large utun MTU + tun2socks TCP auto-tuning |

See `Sources/LoaderCore/AntiCensorship.swift` and a generated example in
`examples/sample-xray-config.json`.

## Checks, statistics and reminders

Shared with the iPhone app through LoaderCore (`LeakCheck`, `SpeedTester`,
`TrafficLedger`, `SubscriptionInfo`, `LearnedMasking`):

* **Check Servers** (Servers → ✓ seal): a throwaway `xray` per server (SOCKS
  inbound on a free port, server dial pinned to the physical interface — or
  through the tunnel while an armed kill switch allows nothing else) makes one
  real HTTPS request (`gstatic.com/generate_204`). Servers that answer pings but
  carry nothing are marked with the reason ("TLS error", "No response through
  the proxy"…) and drop out of the automatic pick and the failover ladder.
  Blocked TCP servers are retried with Maximum, then Yandex masking; what gets
  one through is learned. WireGuard-family and Hysteria servers keep their
  ping. The engines are killed at quit (`ProxyCheck.stopAll`).
* **Learned masking per network:** kept per server *and* per kind of network —
  `identityKey#wifi` (Wi‑Fi/Ethernet) and `identityKey#cellular` (mobile data;
  an iPhone hotspot is an expensive path and counts as one); the plain
  `identityKey` entry is the fallback. The same keys travel to and from the
  iPhone in transfer bundles.
* **Block ads** (main window, Settings → Protection): the engine's DNS asks
  AdGuard DNS over DoH through the proxy (its host pinned in `dns.hosts`);
  AmneziaWG sessions point the system resolver at AdGuard instead of the
  profile's DNS. Effective under the system tunnel; applies at connect.
* **Leak test** (main window, ⇧⌘L): the exit address (ip.sb, Cloudflare as a
  fallback) through the VPN — via the engine's SOCKS port in proxy-only mode —
  compared with the provider's own address, fetched by `curl --interface
  <physical NIC>` around the tunnel (an armed kill switch blocks that, and the
  test then says so); IPv6; DNS resolvers via bash.ws.
* **Statistics** (click the traffic strip, ⌘Y): today, this month, two weeks,
  top servers — fed by the stats poller; plus a **speed test** against
  Cloudflare (3 streams, ≤10 s or 150/75 MB each way).
* **Subscriptions:** traffic, expiry, title, announcement and links from the
  panel's headers, in Settings and the server list; a notice with **Renew**
  when the selected server's subscription is about to run out; reminders
  three days and a day before it ends and at 90 % traffic (provisional
  notifications first; Settings offers banners). Automatic rounds — the
  launch refresh and the 6-hourly one — fetch only `https://` panels and log
  the skipped ones: a plain-http answer is written by whoever controls the
  path, and a swapped server list is tomorrow's traffic through someone
  else's exit. A panel is also left alone until its own
  `profile-update-interval` has passed — honoured on iOS, where the round runs
  every half-hour and on any return to the foreground; on macOS the round
  itself runs every 6 h, so a panel asking for hourly still waits 6 h, and a
  panel asking for a month is never allowed past 24 h. **Refresh Subscriptions**
  and the per-subscription button load http too, because that's a press you
  made; rows for unencrypted panels carry an open-lock mark. The decision is
  one function (`Subscription.refreshIsDue`) shared with the iOS store and
  mirrored byte-for-byte in the Kotlin port.

## Transfer to iPhone

Settings → General → **Transfer to iPhone** moves the servers added by hand,
the subscriptions (their addresses — each device fetches the lists itself)
and the shared settings (masking, kill switch, split tunneling, learned
masking, block ads) to Anemia on an iPhone or another Mac, and back:

* **Share…** (AirDrop, Messages…) or **Save File…** writes an `.anemia` file;
  **Show QR Code** shows a code the iPhone scans (Servers → + → Scan QR).
* **Import File…**, or paste an `anemia://sync/…` link / drop an `.anemia`
  file into Import: a preview says what's new; servers already present (same
  endpoint and key) aren't duplicated, settings are taken only when asked.

The format is `LoaderCore/SyncBundle.swift` (JSON; the link form is
base64url of zlib-deflated JSON). The selection stays per device. The file
holds server keys — don't publish it.

## Build & test

```bash
bash Scripts/test.sh        # every suite (swift-testing), Xcode or Command Line Tools
bash Scripts/build-app.sh   # release, arm64 → /tmp/Anemia.app
```

The scripts adapt to the standalone Command Line Tools: they pin a pre-27 SDK
when the SwiftUI macro plugin is missing, and point the Swift Build engine at
the swift-testing macro plugin (the CLT ships no XCTest).

> **Note:** this project lives under `~/Documents`, which is iCloud-managed and
> stamps freshly-built bundles with extended attributes that `codesign` rejects.
> The scripts build in `/tmp/loader-build` (override with `SCRATCH=`).

## Running the engine (dev)

The app needs an `xray` binary. For development, point it at a local install:

```bash
export LOADER_XRAY_PATH=/opt/homebrew/bin/xray
```

Or bundle it into `Resources/xray` for a release build (see
`Scripts/fetch-cores.sh`).

## Dev testing (helper)

The system tunnel needs the privileged helper registered with launchd. The app
installs it itself (Settings → Privileged helper); for an unbundled dev build:

```bash
swift build --scratch-path /tmp/loader-build
sudo bash Scripts/install-helper-dev.sh      # installs LaunchDaemon + tun2socks
export LOADER_XRAY_PATH="$PWD/Resources/xray" # so the app finds the engine
# run the app, import a real server, Connect
sudo bash Scripts/uninstall-helper-dev.sh    # restores the network, removes the helper
```

## Status

- [x] LoaderCore: parsing (vless/vmess/ss/trojan/hysteria2/AmneziaWG) + subscriptions
- [x] LoaderCore: Xray config builder with Reality/Vision + fragment + noises + mux
- [x] Config validated end-to-end against real Xray v26.3.27 (`xray run -test`)
- [x] Persistence (servers, subscriptions, selection, anti-DPI options)
- [x] XrayController (process supervision, log streaming, native Stats API)
- [x] Helper: utun + split-default routing + tun2socks bridge, IPv6 anti-leak
- [x] Kill switch (pf anchor, fail-closed, stateless rules)
- [x] Network-safety journal, launch recovery, watchdog, graceful SIGTERM
- [x] Network repair (helper XPC, admin-prompt fallback, standalone script)
- [x] XPC client code-signature verification
- [x] Ping-on-launch → auto-connect fastest; kxc v4 Core ML ranker — forecasts each server's next probes (`bash Scripts/train-kxc.sh --install` retrains, evaluates and installs only if it beats every baseline)
- [x] Post-connect health check, recovery ladder, network-change revalidation
- [x] Apple Silicon: arm64 release build with cross-module optimization; engines
      thinned to arm64; packet path (tun2socks / amneziawg-go) at user-interactive QoS
- [x] Check Servers (real requests via throwaway engines), leak test, statistics, speed test, block ads, subscription info and reminders, learned masking per network
- [x] swift-testing suites (276 tests) runnable without Xcode
- [ ] Developer ID code signing + helper install via SMAppService
- [ ] Verify the full system tunnel end-to-end as root against a live server
