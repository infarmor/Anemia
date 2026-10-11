# Anemia for Windows

Windows port of the macOS **Anemia** (Loader) VPN client: an Xray-core
wrapper with anti-DPI features — Reality / XTLS-Vision, TLS ClientHello
fragmentation, junk-noise packets, and stealth-SNI mimicry tuned against
Russian TSPU inspection.

Same engine (Xray-core), same share-link surface (vless / vmess / ss /
trojan, all transports), same anti-censorship profiles — rebuilt in C#
so the whole core is unit-tested and cross-buildable from any host.

## UI

The WPF window mirrors the macOS RootView design (warm Claude theme,
ported from `Theme.swift` — ivory/charcoal gradient, terracotta accent,
serif display type, soft-shadow card tiles). Top bar carries the brand,
the status cluster (lamp · status · session timer · latency · live
throughput), the connect switch and settings; below it the server card
(opens the server picker sheet), Fastest/Ping actions, a one-tile
traffic readout, the protection tile (kill switch / DPI masking /
traffic mode) and the log tail. Light and dark palettes are both
first-class and follow the system appearance live. The tray icon
exposes the same connect toggle and a fast server submenu.

## Layout

| Project | Role | macOS analogue |
|---|---|---|
| `src/AnemiaCore` | Parsers, config builder, stats API, persistence — pure .NET, fully unit-tested | `LoaderCore` + `LoaderShared` |
| `src/AnemiaApp` | WPF window + tray icon, connection state machine, system proxy | `LoaderApp` |
| `src/AnemiaHelper` | Elevated tunnel supervisor: tun2socks/wintun, routes, firewall kill switch | `LoaderHelper` + `LoaderTool` |
| `tests/AnemiaCoreTests` | 634 xunit tests: the Swift suite's cases plus parity checks against the shared goldens | — |
| `tools/AnemiaTool` | CLI over AnemiaCore; `verify-configs.sh` feeds its configs to the real `xray`, `verify-hysteria.sh` its YAML to `hysteria`, `verify-traffic.sh` and `verify-sync.sh` its `traffic.json` and its transfer bundle to the Swift decoder | `LoaderTool` |

The app runs **unprivileged** (asInvoker). Privileged work — the wintun
adapter, the route table, the fail-closed firewall policy — happens in
`AnemiaHelper`, launched elevated (one UAC prompt) over a named-pipe
JSON channel the first time a TUN tunnel is requested.

## Checked against the other ports

`Android/core/src/test/resources` holds fixtures and goldens generated from the
Swift sources by `LoaderTool`; the same files pin Kotlin, and now pin C#:

```sh
bash windows-version-alpha/Scripts/test.sh   # build + 634 tests + four contours
```

Currently green against Swift's own answers — one line per shared fixture, with
the count measured from the file rather than estimated:

| Fixture | What is compared |
|---|---|
| `sub/numbers.tsv` | 104 strtod/hex-float parses, as IEEE-754 bits |
| `sub/headers.golden.txt`, `sub/due.golden.txt` | 17 header blocks; 40 refresh rows (32 verdicts + 8 loud refusals) |
| `engine/cases.golden.txt` | 34 engine-log chains → the innermost cause |
| `health/cases.golden.txt`, `health/run.golden.txt` | 38 + 36 tunnel-health verdicts |
| `switch/due.golden.txt`, `switch/budget.golden.txt` | 42 + 24 auto-switch pacing decisions |
| `score/histories.golden.txt` | 38 histories × 3 scores + 25 kxc features, every number a bit pattern |
| `score/ledger.golden.txt` | 7 traffic scenarios (387 readings and questions) + the 7 documents Swift wrote, read back through `TrafficLedger.FromJson` |
| `hysteria/links.golden.txt` | 44 cases, YAML compared as base64 |
| `awg/*.conf`, `awg/links.txt` | 11 confs rendered to UAPI scripts with their validator lines, 15 AWG links |
| `bypass/lines.golden.txt` | 60 split-tunnel rules (36 entries, 27 refusals), IPv6 printed exactly as macOS' `inet_ntop` prints it |
| `country/names.tsv`, `country/codes.tsv` | 26 server names → code/flag/place; 20 arbitrary country codes → the found/not-found decision |
| `leak/answers.golden.txt` | 52 service answers (12 ip.sb, 16 trace, 13 bash.ws, 11 verdicts; 13 refusals) |
| `sync/looks/cases.golden.txt`, `sync/carry/cases.golden.txt` | 9 bundle-recognition rows (5 «да»); 7 refresh scripts → which old id each new server inherits |
| `sync/cases.golden.txt` | 35 bundle cases: 22 refusals and reads, the `.anemia` file **byte for byte**, the `anemia://sync/` QR link **byte for byte**, and 8 merges |
| `base64/cases.golden.txt` | 56 inputs → the exact bytes Foundation's ignore-unknown decoder made (19 of them are `nil`) |
| `links/corpus.golden.txt` | 114 share links → all 34 parsed fields each, or the same refusal in the same words (83 refusals: plugins, removed transports, broken base64, an unsupported container) |
| `state/cases.golden.txt` | 20 saved-state files → the re-encoded document (18 decode, 2 throw like Swift does), including its `\/` escaping and reference-date stamps |

Not wired yet: `xray/` — the engine-side config fixtures the builder already
covers through `verify-configs.sh` (which is where `links/corpus.golden.txt`
gets its second half: 29 of the 114 corpus links build a config the real xray
accepts, and the count of unported schemes is now zero).

The state check is the one that pays for strictness: a field this port decodes
leniently where Swift is all-or-nothing does not crash, it quietly writes back a
different document, and the next save from the Mac or the phone carries the
difference. Its rules are mutation-tested (15 mutants of the decoder and the
writer, 13 killed): the two survivors were traced rather than shrugged at — an
enum-casing rule no fixture exercises, now pinned by 13 probes whose answers were
measured from the live Swift decoder (`LoaderTool state` + `state-read`), and one
mutant that a second guard made behaviourally identical to the original, whose
non-equivalent variant (both guards gone) is killed.

## Building

Any .NET 8 SDK (macOS/Linux cross-build the WPF binaries via
`EnableWindowsTargeting`; only *running* needs Windows). On this repo's build
machine `Scripts/dotnet-env.sh` locates a pinned SDK 8.0.425 in the project
cache and prints how to re-fetch it with its published SHA256:

```sh
dotnet build Anemia.sln
dotnet test  tests/AnemiaCoreTests/AnemiaCoreTests.csproj
```

Production publish (both binaries land side by side, which is what the
helper expects, with native cores copied in from `Resources\`):

```powershell
powershell -ExecutionPolicy Bypass -File Scripts\publish.ps1            # win-x64
powershell -ExecutionPolicy Bypass -File Scripts\publish.ps1 -SelfContained
```

## Native dependencies

`Scripts/fetch-cores.ps1` downloads and SHA256-pins into `Resources\`:

- `xray.exe` — Xray-core (the engine)
- `tun2socks.exe` — xjasonlyu/tun2socks (owns the wintun adapter in TUN mode)
- `wintun.dll` — loaded by tun2socks at runtime

The first `xray` run per config shape is validated with `xray run -test`
before launch; verdicts are cached per (server, anti-DPI shape) for the
session.

## What's ported, and the invariants kept

- **Share links**: vless/vmess/ss (SIP002 + legacy)/trojan/awg/amnezia/
  wireguard/wg, transport
  aliases (`h2`, `kcp`, `raw`, `websocket`), Reality params, gRPC
  `mode=multi`. Removed transports (xhttp) and SIP003 plugins fail loudly.
- **Anti-DPI profiles**: Off / Balanced / Maximum / RU·Yandex / RU·VK —
  fragment + noise + mimicry settings byte-identical to the Swift build.
  On engine-level connect failures the client **escalates** up the ladder
  and remembers the learned profile per server (`LearnedMasking`).
- **Saved integers are 64-bit, as Swift's `Int`** (fixed 2026-09-30). The AWG
  junk/padding counts and `muxConcurrency` were read into `int`, so a document
  written by a Mac or phone holding `junkPackets: 5000000000` cost this port the
  **whole server** (measured through `LoaderTool state`: the Mac keeps four
  servers, the port kept one), and `muxConcurrency: 5000000000` quietly became
  the default 8 — a config that starts while the other three ports' config is
  refused by the engine. The width now follows the other ports: the number is
  stored, and the *daemon's* bounds (u32 for `jc/jmin/jmax`, u16 for `S1…S4`)
  are what refuse it. `AwgNumberWidthTests` pins both directions, and
  `state-read` on the file C# writes back answers identically.
- **Invariants preserved** (all covered by tests):
  - never emit `tcpFastOpen` (Xray-core #989 — EINVAL on dial);
  - always emit the `tcpKeepAliveIdle=30` + `tcpKeepAliveInterval=10` pair;
  - never emit `allowInsecure` (removed in Xray 26.x);
  - mimicry stealth-SNI only for Reality, never plain TLS;
  - mux disabled under XTLS-Vision;
  - DNS: DoH through the proxy + the server's own domain pinned in
    `dns.hosts`, so resolving the server never loops through the tunnel;
  - QUIC blocked at the routing layer (TCP is the path the obfuscation
    actually secures).
- **Traffic stats**: native gRPC-over-h2c `StatsService.QueryStats`
  client, with an `xray api statsquery` CLI fallback.
- **Reliability**: free-port picks before bind, readiness gate (SOCKS
  port must answer *and* the process must still be alive), stale-run
  guards on stop/start races, exponential-backoff auto-reconnect,
  history store with corrupt-backup + salvage decoding.
- **Failover**: three consecutive failed end-to-end health checks
  (~1 min of a "working" but dead tunnel) force a reconnect through the
  same ladder as a crash — including masking escalation.
- **Server ranking**: replacement for the macOS CoreML ranker — median of
  recent handshake history (⅔) blended with a fresh probe (⅓); the tray's
  **Servers** submenu fast-switches, and auto-connect with no explicit
  selection picks the best-ranked server.
- **Subscriptions**: auto-refresh on launch and every 6 h when the flag
  is on; refreshes preserve identity keys, so selection and ping history
  survive updates.

## TUN mode & kill switch

When the kill switch (or TUN routing) is on, the helper:

1. flips the firewall to **default-deny outbound** in all profiles
   (fail-closed — the seal exists before any exception does);
2. allows only loopback, `xray.exe` / `tun2socks.exe` / `Anemia.exe`,
   DHCP renewals, and the VPN server's IP (the /32 bypass);
3. spawns tun2socks on device `anemia`, addresses it `198.18.0.1/24`,
   routes default via `198.18.0.2` and the server's /32 via the
   *original* gateway;
4. points system DNS at the tunnel (the engine hijacks :53 → DoH);
5. installs the local-bypass routes on that original gateway, and the
   firewall allow rules for the same destinations — a route into a
   sealed machine is a destination that resolves and never connects.

Teardown is the reverse and idempotent; the helper also repairs
crash-orphaned state on every boot. Neither the routes nor the rules it
touches have been run on a Windows machine yet — see the split-tunnel
note under *Not ported yet*.

## Proxy-only mode

Without the helper (UAC declined, binary missing), the client falls back
to a plain local proxy: SOCKS `127.0.0.1:10808`, HTTP `127.0.0.1:10809`,
optionally set as the system proxy via WinINet — always cleared on
disconnect, never left stale.

## State

`%APPDATA%\Anemia\state.json` (servers, subscriptions, selection,
masking profile, learned masking), `panels.json` (what each panel's headers said
— quota, expiry, its own refresh interval; kept out of `state.json` so that file
stays byte-for-byte Swift's) and `history.json` (ping history,
rolling 256 samples per server). Malformed state is salvaged entry-wise
and backed up as `.corrupt-<ts>.bak` before reset.
## Not ported yet

Stated out loud, because none of it fails loudly today — a link of an unknown
scheme is simply refused as `UnsupportedScheme`:

- **AmneziaWG data plane**: the parsing, the key/number validator and the UAPI
  script are ported and pinned (2026-09-27), but nothing spawns
  `amneziawg-go` on Windows yet — the plan is a `GOOS=windows` build beside
  `xray.exe` driving the same wintun adapter tun2socks owns. **The Amnezia
  `vpn://` container is parsed now** (2026-09-29): Qt's qCompress envelope, the
  double-serialized `last_config`, the Xray container that hands its vless link
  back to the ordinary parser, and the 3x-ui form that puts a wg-quick conf
  straight in the payload — all 16 corpus rows match Swift.
- **Hysteria is ported** (2026-09-27): both generations parse (`hysteria://`,
  `hysteria2://`, `hy2://`, port hopping in the authority or `mport=`), the client
  YAML matches Swift byte for byte on all 44 corpus cases, and every one of the 34
  generated configs is accepted by the real `hysteria` binary. In xray's config the
  server becomes a plain `socks` outbound into the bridge port, and building it
  without that port is refused as a wiring bug. **Missing: the process itself** —
  nothing spawns `hysteria.exe` yet, so a hysteria server can be imported, ranked
  and validated but not connected.
  What the engine will *not* catch, measured: hysteria's loader ignores unknown
  fields and even a `tls:` written as a scalar — a misspelled `pinSHA256` means
  the pin is silently off. Field names are therefore pinned by tests, not by the
  binary.
- **Leak *measurement* has no transport yet.** The parsers, the verdict and the
  orchestration are ported — `LeakTestModel.RunAsync` takes the three paths
  (`LeakTestModel.swift`: the endpoint through the tunnel, the same one bound to
  the physical interface outside it, the resolver the six lookups go through)
  and decides `unprotected / failed / unknown / leaks / clean` exactly as the
  other ports do, pinned over `leak/answers.golden.txt`. Missing is the code
  that fills those delegates on Windows — a `SocketsHttpHandler` bound to the
  physical interface's address, which cannot be measured from this machine, and
  the sheet that shows the result. Wiring a UI that can print "clean" without
  ever having measured is the failure mode worth avoiding, so it comes as one
  change.
- **Sync is ported and pinned; the transfer sheet is not.** `SyncBundle` reads,
  merges and writes both forms: the `.anemia` file matches Swift's
  `JSONEncoder` bytes exactly, and the `anemia://sync/` QR link matches too —
  Apple's `.zlib` turned out to be raw DEFLATE (RFC 1951, no zlib header), and
  .NET's `DeflateStream` at `CompressionLevel.Optimal` reproduces those bytes
  byte for byte on every golden payload, while `Fastest` gave 894 against
  Apple's 869. All 35 cases of `sync/cases.golden.txt` are compared in
  `ParitySyncCases`, ten extra shapes the fixture lacks (a poisoned server
  element, a scalar `settings`, an explicit null) were measured through
  `LoaderTool sync` and pinned in `ParitySyncProbes`, and `verify-sync.sh` has
  the real Swift decoder read what this port wrote. **What is missing is the UI
  half**: nothing in `AnemiaApp` exports a file or draws a QR code yet, so the
  logic is ready **and wired**: ⇅ in the header opens the transfer sheet, which writes the `.anemia` file, copies the QR link as text, and previews a merge before importing it. The QR *bitmap* is still not drawn — that needs an encoder this port does not have — and WPF cannot be run on this Mac, so the sheet is compile-verified here and its every decision lives in `AnemiaCore/TransferModel.cs`, which is tested.
- **Country detection is ported, and not yet shown.** `Country` reproduces the
  Swift helper over both shared tables — 26 server names (code, flag, place
  compared exactly) and 20 arbitrary «country codes» as a leak service's `loc=`
  field can arrive (a wrong *decision* fails; a different spelling is reported,
  because names come from the system CLDR). Measured here: this Mac's ICU returns
  the same Russian names as Apple for every fixture code, and its region table is
  a subset of Apple's — 251 of Apple's 280 two-letter codes, plus `IV`, which
  Apple dropped. Nothing renders it yet; the server list and the map labels are
  the consumers, and they are the Russian-UI step.
- **Split tunnel is wired end to end, and the OS half of it is unmeasured.**
  `SplitTunnelParser` reproduces Swift's normalization over the shared
  `bypass/lines.golden.txt` (60 lines: 36 entries, 27 refusals) plus 40 cases
  measured against `LoaderTool split-tunnel` for the parts the shared fixture
  does not cover — the `inet_ntop` shapes, `inet_pton` refusals, the
  63-character label bound and the `://` / `@` trimming. On top of it
  `SplitTunnelPlan` decides the routes: it re-parses what the client sent (the
  app is not the authority on what may be routed around the VPN), caps the
  lists at macOS' 256/64/256, drops fake-IP answers, skips destinations already
  on-link, leaves the engine's own server pin alone, refuses the ranges the
  tunnel lives in, and re-pins known routes with `change` rather than deleting
  a live one. `AnemiaHelper` executes that plan (`start-tunnel` carries the
  lines, `apply-bypass` and `reassert-bypass` change them mid-session, teardown
  removes them), the watchdog re-pins once a minute, and a sealed machine gets
  allow rules for the same destinations — a bypass route into a blocking
  firewall looks configured and is not. 38 tests, 18 mutants all killed.
  **What no test can reach:** the spelling of the `route.exe` arguments and
  reading the adapters (`PrefixLength`, `GatewayAddresses`) are compile-checked
  here against the documented .NET and Windows behaviour, nothing more. The
  helper's IPv6 half depends on a gateway form this machine cannot read.

**Traffic is counted and kept.** `TrafficLedger` is ported and wired: the stats
loop feeds it the engine's cumulative counters together with the instant that
engine run started (`XrayController.RunStartedAt`, written once per spawn — a
stamp recomputed per tick invents a new run and re-bills the whole counter),
`UsageStore` persists it to `%APPDATA%\Anemia\traffic.json` at most every 30 s
on a monotonic clock, `Stopped()` closes the connected stretch when the engine
goes away, and deleted servers leave the "top" board. The file is the same
document the Mac and the phone read — `Scripts/verify-traffic.sh` proves it by
having the real Swift decoder read what C# wrote, twice, so a folder copied
between machines carries the history instead of resetting it. **Not verified on
a machine:** the loop is compile-checked only (WPF does not run here), so the
cadence and the reconnect behaviour need a Windows box.
- **The ranker inputs are ported, the ranker is not used yet.** `ServerScoring`
  and all 25 `KxcFeatures` match Swift bit for bit over `score/histories.golden.txt`
  (38 histories), but `PickBestAsync` still scores with its own median blend —
  switching the button to `RankingScore`/`Stability` changes which server a user
  gets, so it is his call, not a silent rewrite. There is no kxc model on Windows
  (no CoreML equivalent), so the forecast factor iOS applies is absent by design.

## Reliability rules are the shared ones

`TunnelHealth`, `HealthSchedule`, `AutoSwitchPolicy` and `SwitchBudget` are the
same predicates macOS, iOS and Android run, pinned by `health/`, `switch/` and
`engine/` goldens, and the app now acts through them
(`AppState.TryFailover`): the failover needs two consecutive failed checks, a
session older than a minute, at most three moves per 15 minutes and three minutes
between them, and a *frozen* failure counter is treated as no evidence at all.
Both the health loop and the 5 s watchdog act through that one ledger — before
this, a blocked server was torn down and rebuilt every 25 s for as long as it
stayed blocked, with no cap and no pause. Engine startup failures are reported
through `EngineLog` too, so the user sees the innermost cause instead of a
temp-config path.

**Behaviour change, not verified on a machine**: this pacing (and "a check that
answered in over 3 s counts as a failure") is new to Windows and can only be
confirmed against a live, partially blocked server. The numbers themselves are
gold-tested; the loop they now drive is not.
- **UI copy is English.** macOS, iOS and Android are Russian, including the
  plural agreement («1 сервер / 2 сервера / 5 серверов») the row counts use.
- **UUID shape is not checked anywhere** (all four ports): a malformed
  percent-escape in a link's userinfo reaches the engine, which dies with
  `common/uuid: invalid UUID` — case 100 of `links/corpus.txt`, and `verify-configs.sh`
  reports it as the single engine refusal. Fixing it in one port only would
  diverge them, so it needs the paired Swift + Kotlin + C# change and a corpus
  fixture.
