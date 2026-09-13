# Anemia (macOS)

VPN client for macOS that bypasses network blocking by wrapping the
**Xray-core** engine. Traffic is made unreadable and hard to fingerprint using
Xray's native anti-DPI features — Reality/XTLS-Vision, TLS ClientHello
fragmentation, and junk-noise packets — while staying fast.

> Legitimate censorship-circumvention / privacy tool. You are responsible for
> complying with the laws that apply to you.

## Architecture

```
┌──────────────────────────────────────────────┐
│ LoaderApp  (menu-bar SwiftUI, unprivileged)   │
│  • import vless/vmess/ss/trojan + subscriptions│
│  • XrayConfigBuilder → xray-core JSON          │
│  • XrayController: spawns `xray run -c cfg`     │
│  • HelperClient: XPC → privileged helper        │
└───────────────┬───────────────┬────────────────┘
                │ SOCKS/HTTP     │ XPC (root)
                ▼                ▼
        127.0.0.1:10808   ┌───────────────────────┐
        (xray inbounds)   │ LoaderHelper (root)   │
                          │  • create utun         │
                          │  • program routes      │
                          │  • tun2socks → SOCKS   │
                          └───────────────────────┘
```

* **LoaderCore** — pure, unit-tested logic: share-link/subscription parsing and
  Xray config generation (incl. anti-DPI). No UI, no root.
* **LoaderShared** — the XPC contract shared by app and helper.
* **LoaderApp** — the menu-bar client.
* **LoaderHelper** — privileged helper: utun + routing + tun2socks bridge.

### Anti-DPI ("junk") mapping

| Requirement                | Xray feature                              |
|----------------------------|-------------------------------------------|
| Traffic can't be read      | VLESS + **Reality** + **XTLS-Vision** (TLS 1.3, real-site handshake mimicry) |
| Protect with junk          | `sockopt.noises` (junk packets) + `fragment` (ClientHello shredding) |
| Fast                       | XTLS-Vision splice, TCP Fast Open, uTLS `chrome` fingerprint |

See `Sources/LoaderCore/AntiCensorship.swift` and a generated example in
`examples/sample-xray-config.json`.

## Build & test

```bash
swift test          # runs the LoaderCore + LoaderHelper test suites
swift build         # builds the package
```

> **Note:** this project lives under `~/Documents`, which is iCloud-managed and
> stamps freshly-built bundles with extended attributes that `codesign` rejects
> (`resource fork, Finder information, or similar detritus not allowed`). Build
> with a scratch path outside that tree:
>
> ```bash
> swift test  --scratch-path /tmp/loader-build
> swift build --scratch-path /tmp/loader-build
> ```

## Running the engine (dev)

The app needs an `xray` binary. For development, point it at a local install:

```bash
export LOADER_XRAY_PATH=/opt/homebrew/bin/xray
```

Or bundle it into `Resources/xray` for a signed release build (see
`Scripts/fetch-cores.sh`).

## Dev testing (helper)

The system tunnel needs the privileged helper registered with launchd so the
app's XPC connection can reach it. On an unsigned dev build:

```bash
swift build --scratch-path /tmp/loader-build
sudo bash Scripts/install-helper-dev.sh      # installs LaunchDaemon + tun2socks
export LOADER_XRAY_PATH="$PWD/Resources/xray" # so the app finds the engine
# run the app, import a real server, Connect
sudo bash Scripts/uninstall-helper-dev.sh    # when done
```

The engine (`xray`) and tun2socks live in `Resources/` (built by
`Scripts/fetch-cores.sh`). Every generated config is validated against the real
Xray binary — all four protocols report `Configuration OK`.

## Status

- [x] LoaderCore: parsing (vless/vmess/ss/trojan) + subscriptions
- [x] LoaderCore: Xray config builder with Reality/Vision + fragment + noises + mux
- [x] Config validated end-to-end against real Xray v26.3.27 (`xray run -test`)
- [x] Persistence (servers, subscriptions, selection, anti-DPI options)
- [x] XrayController (process supervision, log streaming)
- [x] Menu-bar UI (connect, server list, import, logs)
- [x] HelperClient XPC wrapper
- [x] xray-core + tun2socks release binaries, SHA256-pinned (`Scripts/fetch-cores.sh` → `Resources/`)
- [x] LoaderHelper: utun + split-default routing + tun2socks bridge (needs root testing)
- [x] IPv6 tunneling + DNS-leak protection (remote DNS)
- [x] Kill switch (pf, fail-closed) — `Sources/LoaderHelper/KillSwitch.swift`
- [x] XPC client code-signature verification
- [x] Live traffic stats via Xray Stats API
- [x] Black windowed UI; connect controlled from the top-bar switch; live timer + stats
- [x] Ping-on-launch → auto-connect fastest; per-server TCP ping badges; one-tap switch in the fast menu
- [x] kxc: on-device CoreML neural ranker (fp16) for fastest-server selection; settings show status + compute device
- [x] Post-connect health check (real latency through the tunnel)
- [x] Apple Silicon: arm64 release build (`-O`), stripped Go cores; CoreML `.cpuAndNeuralEngine`
- [x] Masking profiles (Off / Balanced / Max) + selectable uTLS fingerprint
- [x] DoH DNS (encrypted, proxied) — anti-leak / anti-tamper
- [x] Stability: free-port selection, pre-launch `xray -test` validation, auto-reconnect with backoff
- [x] `.app` assembly script (`Scripts/build-app.sh`)
- [ ] Developer ID code signing + helper install via SMAppService
- [ ] Verify the full system tunnel end-to-end against a live server
```
