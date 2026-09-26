import Foundation
import LoaderCore

// Tiny CLI for scripting and for validating output against the real engines:
//   LoaderTool emit "vless://…" | xray run -c /dev/stdin -test
//   LoaderTool awg-uapi awg.conf        # the UAPI script the helper pushes into amneziawg-go
//   LoaderTool hysteria-yaml "hy2://…"  # the hysteria client config (bridge on 127.0.0.1:21180)

/// Поля разобранной ссылки — один и тот же набор печатают `dump-links` и
/// `sub`, чтобы сверка подписки не молчала о половине модели.
func linkFieldPairs(_ s: ProxyServer) -> [(String, String)] {
    let fields: [(String, String)] = [
        ("name", s.name), ("proto", s.proto.rawValue), ("address", s.address),
        ("port", String(s.port)), ("credential", s.credential), ("method", s.method ?? ""),
        ("alterId", String(s.alterId)), ("vmessCipher", s.vmessCipher ?? ""),
        ("network", s.network.rawValue), ("security", s.security.rawValue),
        ("sni", s.sni ?? ""), ("alpn", s.alpn.joined(separator: ",")),
        ("fingerprint", s.fingerprint ?? ""), ("allowInsecure", String(s.allowInsecure)),
        ("realityPublicKey", s.realityPublicKey ?? ""), ("realityShortId", s.realityShortId ?? ""),
        ("realitySpiderX", s.realitySpiderX ?? ""), ("flow", s.flow ?? ""),
        ("path", s.path ?? ""), ("host", s.host ?? ""), ("headerType", s.headerType ?? ""),
        ("grpcMultiMode", s.grpcMultiMode.map(String.init) ?? ""),
        ("xhttpMode", s.xhttpMode ?? ""), ("xhttpExtra", s.xhttpExtra ?? ""),
        ("vlessEncryption", s.vlessEncryption ?? ""),
        ("awgVersion", s.proto.isWireGuardFamily ? s.awgVersion.rawValue : ""),
        ("wgAddresses", s.userData?["wgAddress"] ?? ""),
        // The peer profile is what the AWG engine actually consumes, so a link
        // parser that fills it wrong is invisible in every other field.
        ("wgPeer", s.wgProfile?.peerPublicKey ?? ""),
        ("wgPreshared", s.wgProfile?.presharedKey ?? ""),
        ("wgAllowedIPs", s.wgProfile?.allowedIPs.joined(separator: ", ") ?? ""),
        ("wgDNS", s.wgProfile?.dns.joined(separator: ", ") ?? ""),
        ("wgMTU", s.wgProfile?.mtu.map(String.init) ?? ""),
        ("wgKeepAlive", s.wgProfile?.keepAlive.map(String.init) ?? ""),
        ("userData", (s.userData ?? [:]).sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: ";")),
    ]
    return fields
}

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: LoaderTool emit <share-link> [--no-anti] [--profile <name>]
           LoaderTool emit-tun <share-link|conf> [--no-anti] [--profile <name>]
                                    [--mtu <n>] [--bypass a,b] [--adblock] [--log <path>]
           LoaderTool awg-uapi <wg-quick conf file | amnezia:// / wireguard:// / vpn:// link>
           LoaderTool hysteria-yaml <hysteria2:// link> [--socks-port <port>]
           LoaderTool dump-links <file>   # parsed fields, one block per share link
           LoaderTool b64 <file>          # flexible base64 of each line, hex or nil
           LoaderTool number <file>     # Foundation Double(String): bits, nil/inf/nan per hex case
           LoaderTool split-tunnel <file> # one bypass rule set per line
           LoaderTool sub <file>          # subscription bodies, one per line
           LoaderTool subinfo <file>      # subscription headers, one set per line
           LoaderTool subdue <file>       # auto-refresh verdict, one panel per line
           LoaderTool state <dir>         # PersistedState cases: decode, load, backups
           LoaderTool state-read <file…>  # a state file from another platform

    """.utf8))
    exit(2)
}

func describeParseError(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? "\(error)"
}

func fail(_ error: Error) -> Never {
    FileHandle.standardError.write(Data("error: \(describeParseError(error))\n".utf8))
    exit(1)
}

/// The encoder the apps write their state with, minus the pretty printing —
/// compact and key-sorted is the same document, only easier to diff.
func stateEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
}

/// A fixture line is one case, so the payloads that really contain newlines
/// carry them as `\n` / `\r` escapes.
/// Поле фикстуры по индексу. Файлы правятся руками, и недостающий хвост
/// строки должен становиться видимой ошибкой кейса, а не `Index out of range`
/// посреди генерации эталона.
func field(_ parts: [String], _ i: Int) -> String? { i >= 0 && i < parts.count ? parts[i] : nil }

/// Узкие целые из текста: `UInt16(x)` ловит trap на выходе за диапазон, а
/// `UInt16(x) ?? 0` от trap не спасает — этот инициализатор не optional.
func u16Field(_ text: String?) -> UInt16? {
    text.flatMap { Int($0) }.flatMap { UInt16(exactly: $0) }
}

func u8Field(_ text: String?, radix: Int = 10) -> UInt8? {
    text.flatMap { Int($0, radix: radix) }.flatMap { UInt8(exactly: $0) }
}

/// Hex фикстуры: нечётный nibble и посторонний символ — ошибка кейса, а не
/// молча проглоченный байт (Kotlin на то же место роняет проверку).
func hexBytes(_ text: String) -> Data? {
    guard text.count % 2 == 0, text.allSatisfy(\.isHexDigit) else { return nil }
    var data = Data()
    data.reserveCapacity(text.count / 2)
    var rest = Substring(text)
    while !rest.isEmpty {
        guard let byte = UInt8(rest.prefix(2), radix: 16) else { return nil }
        data.append(byte)
        rest = rest.dropFirst(2)
    }
    return data
}

func unescaped(_ text: String) -> String {
    var out = ""
    var rest = Substring(text)
    while let slash = rest.firstIndex(of: "\\") {
        out += rest[..<slash]
        rest = rest[rest.index(after: slash)...]
        guard let kind = rest.first else { break }
        rest = rest.dropFirst()
        switch kind {
        case "n": out += "\n"
        case "r": out += "\r"
        case "t": out += "\t"
        case "\\": out += "\\"
        case "v": out += "\u{0B}"
        case "f": out += "\u{0C}"
        default: out += "\\\(kind)"
        }
    }
    return out + rest
}

/// The leak screens' answers, printed in one canonical shape both platforms can
/// be compared on. `nil` fields are `-`, and a whole missing reading is `NONE`.
func ipInfoDump(_ info: LeakCheck.IPInfo) -> String {
    "ip=\(info.ip) cc=\(info.countryCode ?? "-") country=\(info.country ?? "-")" +
        " city=\(info.city ?? "-") isp=\(info.isp ?? "-")"
}

func dnsDump(_ server: LeakCheck.DNSServer) -> String {
    "ip=\(server.ip) cc=\(server.countryCode ?? "-") country=\(server.country ?? "-")" +
        " org=\(server.org ?? "-")"
}

func infoField(_ text: String) -> LeakCheck.IPInfo? {
    guard text != "NONE" else { return nil }
    let parts = text.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 5 else { return nil }
    func optional(_ value: String) -> String? { value == "-" ? nil : value }
    return LeakCheck.IPInfo(ip: parts[0], countryCode: optional(parts[1]), country: optional(parts[2]),
                            city: optional(parts[3]), isp: optional(parts[4]))
}

func dnsField(_ text: String) -> [LeakCheck.DNSServer] {
    guard text != "-" else { return [] }
    return text.split(separator: ";").compactMap { item in
        let parts = item.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4 else { return nil }
        func optional(_ value: String) -> String? { value == "-" ? nil : value }
        return LeakCheck.DNSServer(ip: parts[0], countryCode: optional(parts[1]),
                                   country: optional(parts[2]), org: optional(parts[3]))
    }
}

/// A Double as its exact IEEE-754 bits. Decimal printing is deliberately not
/// used: these numbers are computed twice, on two platforms, and the last bit
/// is precisely the thing worth comparing — while each printf's idea of " enough
/// digits" differs between libSystem and the JVM.
func exact(_ value: Double) -> String {
    String(repeating: "0", count: 16 - String(value.bitPattern, radix: 16).count)
        + String(value.bitPattern, radix: 16)
}
func number(_ text: String) -> Double? {
    Double(text)
}

func dayDump(_ day: TrafficLedger.Day) -> String {
    "id=\(day.id) recv=\(day.received) sent=\(day.sent) time=\(exact(day.time)) total=\(day.total)"
}

/// Canonical JSON of a document, or nil when it isn't JSON at all.
func canonicalJSON(_ data: Data) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
          let out = try? JSONSerialization.data(withJSONObject: object,
                                                options: [.sortedKeys, .fragmentsAllowed])
    else { return nil }
    return String(decoding: out, as: UTF8.self)
}

// MARK: - Sync bundle cases

func runSyncCase(_ kind: String, _ caseObject: [String: Any]) {
    switch kind {
    case "read":
        guard let body = caseObject["body"] as? String else { print("error\tno body"); return }
        do {
            print("bundle\t" + bundleDump(try SyncBundle.decode(Data(body.utf8))))
        } catch let error as SyncBundle.DecodeError {
            print("error\t" + syncErrorDump(error))
        } catch {
            print("error\tdeserialize")
        }

    case "file":
        guard let bundle = bundleFrom(caseObject["bundle"]) else { print("error\tcase"); return }
        let written = try? bundle.fileData()
        print("file\t\(written.flatMap { canonicalJSON($0) } ?? "throw")")
        // The exact bytes, base64'd: a bundle file carries no floating point,
        // so the two platforms can and must agree on them character for character.
        print("file-bytes\t\(written?.base64EncodedString() ?? "throw")")
        if let written, let back = try? SyncBundle.decode(written) {
            print("file-read\t" + bundleDump(back))
        } else {
            print("file-read\tthrow")
        }

    case "link":
        guard let bundle = bundleFrom(caseObject["bundle"]) else { print("error\tcase"); return }
        let text = try? bundle.link()
        print("link\t\(text ?? "throw")")
        if let text, let back = try? SyncBundle.fromLink(text) {
            print("link-read\t" + bundleDump(back))
        } else {
            print("link-read\tthrow")
        }

    case "merge":
        guard let bundle = bundleFrom(caseObject["bundle"]),
              let stateData = try? JSONSerialization.data(withJSONObject: caseObject["state"] ?? [:]),
              var state = try? JSONDecoder().decode(PersistedState.self, from: stateData)
        else { print("error\tcase"); return }
        let summary = bundle.merge(into: &state,
                                   applySettings: (caseObject["apply"] as? Bool) ?? true)
        print("summary\tadded=\(summary.addedServers) known=\(summary.knownServers)" +
              " new=\(summary.newSubscriptions.count) knownSubs=\(summary.knownSubscriptions)" +
              " settings=\(summary.settingsApplied ? 1 : 0) nothing=\(summary.addsNothing ? 1 : 0)")
        // The state is dumped by what a merge can decide about — names, counts,
        // settings — not by UUID: an id the merge had to invent is random, and a
        // golden that carried it would be flaky by construction.
        let ids = state.servers.map { $0.id }
        print("after\tcount=\(state.servers.count)" +
              " unique=\(Set(ids).count == ids.count ? 1 : 0)" +
              " names=" + state.servers.map(\.name).joined(separator: ";") +
              " selected=" + (state.selectedServerID.map { id in
                  state.servers.first?.id == id ? "first" : "other"
              } ?? "-") +
              " subs=" + state.subscriptions.map { "\($0.name)@\($0.url)" }.joined(separator: ";") +
              " masking=\(state.maskingProfile.rawValue) kill=\(state.killSwitchEnabled ? 1 : 0)" +
              " subref=\(state.subscriptionAutoRefresh ? 1 : 0)" +
              " learned=" + state.learnedMasking.sorted { $0.key < $1.key }
                  .map { "\($0.key)=\($0.value)" }.joined(separator: ";") +
              " split=" + (state.splitTunnel.enabled ? "on" : "off") + ":" +
              state.splitTunnel.entries.joined(separator: ","))

    default:
        print("error\tunknown kind \(kind)")
    }
}

func bundleFrom(_ value: Any?) -> SyncBundle? {
    guard let value,
          let data = try? JSONSerialization.data(withJSONObject: value)
    else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(SyncBundle.self, from: data)
}

/// The bundle reduced to what a merge decision depends on: which servers, which
/// subscription addresses, which settings — plus the export stamp.
func bundleDump(_ bundle: SyncBundle) -> String {
    let seconds = bundle.exportedAt.timeIntervalSince1970
    return [
        "version=\(bundle.version)",
        "device=\(bundle.device)",
        "at=\(seconds < Double(Int64.max) ? String(Int64(seconds)) : "overflow")",
        "servers=" + bundle.servers.map(\.identityKey).joined(separator: ";"),
        "subs=" + bundle.subscriptions.map { "\($0.name)@\($0.url)" }.joined(separator: ";"),
        "settings=" + (bundle.settings.map(settingsDump) ?? "nil"),
    ].joined(separator: " ")
}

func settingsDump(_ settings: SyncBundle.Settings) -> String {
    func flag(_ value: Bool?) -> String { value.map { $0 ? "1" : "0" } ?? "-" }
    let learned = settings.learnedMasking.map { masks in
        masks.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ";")
    } ?? "-"
    let split = settings.splitTunnel.map { "\($0.enabled ? "on" : "off"):" + $0.entries.joined(separator: ",") } ?? "-"
    return "masking=" + (settings.maskingProfile?.rawValue ?? "-")
        + " kill=" + flag(settings.killSwitchEnabled)
        + " split=" + split
        + " learned=" + learned
        + " subref=" + flag(settings.subscriptionAutoRefresh)
        + " adblock=" + flag(settings.adBlock)
        + " reconnect=" + flag(settings.autoReconnect)
        + " autoswitch=" + flag(settings.autoSwitch)
        + " adaptive=" + flag(settings.adaptiveMasking)
}

func syncErrorDump(_ error: SyncBundle.DecodeError) -> String {
    switch error {
    case .notABundle: return "notABundle"
    case .newerVersion(let version): return "newerVersion(\(version))"
    }
}

/// A conf file path, or a share link.
func server(from input: String) throws -> ProxyServer {
    if FileManager.default.fileExists(atPath: input) {
        return try ShareLinkParser.parseConfigText(String(contentsOfFile: input, encoding: .utf8))
    }
    return try ShareLinkParser.parse(input)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { usage() }

switch cmd {
case "emit":
    guard args.count >= 2 else { usage() }
    var anti: AntiCensorshipOptions = args.contains("--no-anti") ? .off : .recommended
    if let i = args.firstIndex(of: "--profile"), i + 1 < args.count,
       let p = MaskingProfile(rawValue: args[i + 1]) {
        anti = p.options
    }
    do {
        print(try XrayConfigBuilder().makeConfigString(server: try server(from: args[1]), anti: anti))
    } catch {
        fail(error)
    }

case "emit-tun":
    // The shape the packet-tunnel engines get — iOS today, Android next: the
    // `tun` inbound instead of local proxies, Xray's built-in hysteria, and the
    // same fixed parameters TunnelPlan passes. Deterministic on purpose: the
    // log path is the one thing a phone fills in at runtime, so it stays out
    // unless --log asks for it. This is the golden source for the Kotlin port.
    guard args.count >= 2 else { usage() }
    var antiTun: AntiCensorshipOptions = args.contains("--no-anti") ? .off : .recommended
    if let i = args.firstIndex(of: "--profile"), i + 1 < args.count,
       let p = MaskingProfile(rawValue: args[i + 1]) {
        antiTun = p.options
    }
    var builder = XrayConfigBuilder(apiPort: nil, bufferSizeKB: 4)
    // MTU вне 576…65535 валидатор AWG отвергает, а сюда он попадал молча, и
    // nonsense уезжал в эталон, который затем копирует порт.
    let mtuValue = args.firstIndex(of: "--mtu").flatMap {
        args.indices.contains($0 + 1) ? Int(args[$0 + 1]) : nil
    } ?? 1500
    guard (576...65535).contains(mtuValue) else {
        FileHandle.standardError.write(Data("error: --mtu \(mtuValue) вне 576…65535\n".utf8))
        exit(2)
    }
    builder.inboundMode = .packetTunnel(mtu: mtuValue)
    builder.hysteriaMode = .native
    builder.collectsStats = true
    builder.dnsQueryStrategy = "UseIPv4"
    builder.bypassResolver = "77.88.8.8"
    if let i = args.firstIndex(of: "--bypass"), i + 1 < args.count {
        builder.bypass = SplitTunnelParser.parse(text: args[i + 1]).entries
    }
    if args.contains("--adblock") {
        builder.remoteDNS = AdBlockDNS.remoteDNS
        builder.dnsHosts[AdBlockDNS.dohHost] = AdBlockDNS.servers[0]
        builder.bypassResolver = AdBlockDNS.servers[0]
    }
    if let i = args.firstIndex(of: "--log"), i + 1 < args.count {
        builder.logFile = args[i + 1]
    }
    do {
        print(try builder.makeConfigString(server: try server(from: args[1]), anti: antiTun))
    } catch {
        fail(error)
    }

case "awg-uapi":
    guard args.count >= 2 else { usage() }
    do {
        let s = try server(from: args[1])
        guard s.proto.isWireGuardFamily else {
            FileHandle.standardError.write(Data("error: not an AmneziaWG/WireGuard server (\(s.proto.rawValue))\n".utf8))
            exit(1)
        }
        FileHandle.standardError.write(Data("AmneziaWG \(s.awgVersion.rawValue) → \(s.address):\(s.port)\n".utf8))
        let problems = AmneziaWGConfigBuilder.validate(server: s, mtu: s.wgProfile?.mtu ?? 1420)
        for problem in problems {
            FileHandle.standardError.write(Data("problem: \(problem)\n".utf8))
        }
        for warning in AmneziaWGConfigBuilder.warnings(server: s) {
            FileHandle.standardError.write(Data("warning: \(warning)\n".utf8))
        }
        print(try AmneziaWGConfigBuilder.makeUAPISetScript(server: s), terminator: "")
        if !problems.isEmpty { exit(3) }
    } catch {
        fail(error)
    }

case "hysteria-yaml":
    guard args.count >= 2 else { usage() }
    var port = 21180
    if let i = args.firstIndex(of: "--socks-port"), i + 1 < args.count, let p = Int(args[i + 1]) {
        port = p
    }
    do {
        let s = try server(from: args[1])
        for problem in HysteriaConfigBuilder.validate(server: s) {
            FileHandle.standardError.write(Data("problem: \(problem)\n".utf8))
        }
        print(try HysteriaConfigBuilder.makeClientConfig(server: s, socksPort: port), terminator: "")
    } catch {
        fail(error)
    }

case "dump-links":
    // The golden source for the Android port: one normalized block per link,
    // so a Kotlin parser is compared against the Swift model field by field
    // rather than against somebody's memory of it. Keys are sorted, absent
    // values print empty.
    guard args.count >= 2, let text = try? String(contentsOfFile: args[1], encoding: .utf8) else { usage() }
    for line in text.split(separator: "\n") {
        let link = line.trimmingCharacters(in: .whitespaces)
        if link.isEmpty { continue }
        print("=== \(link)")
        do {
            let s = try ShareLinkParser.parse(link)
            let fields = linkFieldPairs(s)
            for (key, value) in fields.sorted(by: { $0.0 < $1.0 }) {
                print("\(key)\t\(value)")
            }
        } catch {
            print("error\t\(describeParseError(error))")
        }
    }

case "split-tunnel":
    // The golden source for the Kotlin port: every line of the fixture file
    // through the same parser the apps use, normalized entry or rejection.
    guard args.count >= 2, let text = try? String(contentsOfFile: args[1], encoding: .utf8) else { usage() }
    for line in text.components(separatedBy: "\n") {
        if line.isEmpty { continue }
        let result = SplitTunnelParser.parse(text: line)
        let parts = result.entries.map { "\($0.value) [\(String(describing: $0))] " }
        print("\(line)\t\(parts.joined())\(result.rejected.map { "нет: \($0.reason)" }.joined(separator: "; "))")
    }

case "sub":
    // Golden source for the Kotlin subscription layer: one payload per line of
    // the fixture (`\n` inside a line stands for a real newline), and for each
    // one what the parser produced — servers in the same field dump
    // `dump-links` writes, plus the lines it could not read.
    guard args.count >= 2, let text = try? String(contentsOfFile: args[1], encoding: .utf8) else { usage() }
    for rawLine in text.split(separator: "\n") {
        // Фикстура — одна строка на случай, поэтому переводы строк в ней
        // записаны escape'ами; Kotlin раскрывает их так же.
        let payload = unescaped(String(rawLine))
        if payload.isEmpty { continue }
        print("=== \(rawLine)")
        let result = SubscriptionParser.parse(payload)
        for server in result.servers {
            // Тот же дамп полей, что и у `dump-links`: раньше `sub` печатал
            // 17 из 34, и половина модели в подписке не сверялась вовсе.
            print("server\t" + linkFieldPairs(server).sorted { $0.0 < $1.0 }
                .map { "\($0)=\($1)" }.joined(separator: " "))
        }
        for failure in result.failures {
            print("failure\t\(failure.line)\t\(failure.error)")
        }
        print("count\t\(result.servers.count) \(result.failures.count)")
    }

case "subinfo":
    // Headers a panel sends, one case per line: `id` then `Key: value` parts
    // tab-separated. The dump is normalized so both platforms can be compared
    // without depending on the HTTP layer that normally provides them.
    guard args.count >= 2, let text = try? String(contentsOfFile: args[1], encoding: .utf8) else { usage() }
    for rawLine in text.split(separator: "\n") {
        let parts = rawLine.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { continue }
        var headers: [String: String] = [:]
        for header in parts.dropFirst() {
            guard let colon = header.firstIndex(of: ":") else { continue }
            headers[String(header[..<colon])] = String(header[header.index(after: colon)...])
        }
        let info = SubscriptionInfo.parse(headers: headers)
        func number(_ value: Int64?) -> String { value.map(String.init) ?? "—" }
        print([
            parts[0],
            "title=" + (info.map { $0.title ?? "—" } ?? "nil"),
            "up=" + number(info?.uploaded),
            "down=" + number(info?.downloaded),
            "total=" + number(info?.total),
            "used=" + number(info?.used),
            "remaining=" + number(info?.remaining),
            "unlimited=" + String(info?.isUnlimited ?? false),
            "fraction=" + (info?.usedFraction.map { String(format: "%.4f", $0) } ?? "—"),
            "expires=" + (info?.expires.map { date -> String in
                let seconds = date.timeIntervalSince1970
                // Годы из заголовка бывают «навсегда»: Int(Double) на таком ловит trap.
                guard seconds < Double(Int64.max), seconds > Double(Int64.min) else { return "overflow" }
                return String(Int(seconds))
            } ?? "—"),
            "interval=" + (info?.updateInterval.map { String(format: "%.0f", $0) } ?? "—"),
            "support=" + (info?.supportURL?.absoluteString ?? "—"),
            "web=" + (info?.webPageURL?.absoluteString ?? "—"),
            "announce=" + (info?.announcement ?? "—"),
        ].joined(separator: "\t"))
    }

case "subdue":
    // Golden source for the auto-refresh decision: one case per line —
    // `label  url  lastUpdated  now  panelInterval  defaultAge  allowInsecure`,
    // empty field meaning nil (and an empty `defaultAge` meaning the default
    // argument itself, so changing that default breaks the golden). Prints the
    // clamped interval and the verdict: the age alone would let a broken clamp
    // hide behind cases that stay on one side of it.
    guard args.count >= 2, let text = try? String(contentsOfFile: args[1], encoding: .utf8) else { usage() }
    /// `Int(Double)` traps on NaN and on infinity, and a trap in the middle of
    /// a fixture would leave the golden truncated — so non-finite prints by name.
    func ageText(_ value: TimeInterval) -> String {
        if value.isNaN { return "nan" }
        if value == .infinity { return "inf" }
        if value == -.infinity { return "-inf" }
        return String(Int(value))
    }
    for rawLine in text.split(separator: "\n") {
        let line = String(rawLine)
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard let label = parts.first, !label.isEmpty else {
            print("error\tno label\t\(line)")
            continue
        }
        // `readLines()` на JVM съедает CR, Swift — нет: без отказа одна и та же
        // фикстура прочиталась бы на двух сторонах по-разному.
        if line.contains("\r") {
            print("\(label)\terror\tcr")
            continue
        }
        guard parts.count == 7 else {
            print("\(label)\terror\tcolumns \(parts.count)")
            continue
        }
        guard !parts[1].isEmpty else {
            print("\(label)\terror\tno url")
            continue
        }
        guard parts[6].isEmpty || parts[6] == "0" || parts[6] == "1" else {
            print("\(label)\terror\tallowInsecure")
            continue
        }
        // Empty means nil; a value that does not parse is the case's error, not
        // a silent "never fetched" — a truncated fixture line must not be read
        // as a decision. The first bad column is the reason reported.
        var problem: String?
        func optionalNumber(_ index: Int, _ name: String) -> Double? {
            let raw = parts[index]
            if raw.isEmpty { return nil }
            guard let value = number(raw) else {
                if problem == nil { problem = name }
                return nil
            }
            return value
        }
        let lastFetched = optionalNumber(2, "lastUpdated")
        let now = optionalNumber(3, "now")
        let interval = optionalNumber(4, "panelInterval")
        let defaultAge = optionalNumber(5, "defaultAge")
        if let problem {
            print("\(label)\terror\t\(problem)")
            continue
        }
        guard let now else {
            print("\(label)\terror\tnow")
            continue
        }
        let sub = Subscription(
            name: label,
            url: parts[1],
            lastUpdated: lastFetched.map { Date(timeIntervalSince1970: $0) }
        )
        let press = parts[6] == "1"
        // Пустой столбец `defaultAge` отдаёт дефолт самого аргумента, а не
        // удвоенную константу: иначе правка дефолта золотой бы не заметила.
        let maxAge = defaultAge.map { sub.refreshMaxAge(panelInterval: interval, defaultAge: $0) }
            ?? sub.refreshMaxAge(panelInterval: interval)
        let due = defaultAge.map {
            sub.refreshIsDue(now: Date(timeIntervalSince1970: now), panelInterval: interval,
                             defaultAge: $0, allowInsecure: press)
        } ?? sub.refreshIsDue(now: Date(timeIntervalSince1970: now), panelInterval: interval,
                              allowInsecure: press)
        print("\(label)\tmaxAge=\(ageText(maxAge))\tdue=\(due ? 1 : 0)")
    }

case "state":
    // Golden source for the Kotlin state layer. Every `case.json` in the
    // directory goes through the same lenient decoder the apps use, and the
    // result is printed as canonical JSON — so a field Kotlin drops, coerces
    // differently or forgets to write shows up as a structure difference rather
    // than as somebody's memory of the schema. `loaded` is the same state read
    // through StatePersistence.load(), which additionally runs the drift
    // detector and the corrupt-store backup; `backups` counts what that left
    // behind after four loads (the prune keeps three).
    guard args.count >= 2 else { usage() }
    let dir = URL(fileURLWithPath: args[1], isDirectory: true)
    for name in ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    where name.hasSuffix(".json") {
        let url = dir.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { continue }
        print("=== \(name.dropLast(5))")
        print("input\t\(canonicalJSON(data) ?? "unparseable")")
        let decoded = try? JSONDecoder().decode(PersistedState.self, from: data)
        if let state = decoded, let written = try? stateEncoder().encode(state) {
            print("decode\t\(canonicalJSON(written) ?? "?")")
        } else {
            print("decode\tthrow")
        }
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("anemia-state-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let stored = work.appendingPathComponent("state.json")
        try? data.write(to: stored)
        let loaded = StatePersistence(fileURL: stored).load()
        let loadedData = try? stateEncoder().encode(loaded)
        print("loaded\t\(loadedData.flatMap { canonicalJSON($0) } ?? "?")")
        let afterFirst = ((try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? [])
            .filter { $0.hasSuffix(".bak") }.count
        print("backup\t\(afterFirst)")
        // Four more loads, a few milliseconds apart so each gets its own
        // timestamp — the prune keeps three, and a same-millisecond collision
        // would silently overwrite one backup and make the count flaky.
        for _ in 0..<4 {
            try? await Task.sleep(nanoseconds: 5_000_000)
            _ = StatePersistence(fileURL: stored).load()
        }
        let backups = ((try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? [])
            .filter { $0.hasSuffix(".bak") }.count
        print("backups\t\(backups)")
        try? FileManager.default.removeItem(at: work)
    }

case "state-read":
    // The other direction: files written by another platform (the Kotlin check
    // puts its own encoding here) read back through the Swift decoder. Equal
    // `decode` lines mean the two platforms agree on the bytes, not just on
    // their own in-memory models.
    guard args.count >= 2 else { usage() }
    for path in args.dropFirst() {
        let name = (path as NSString).lastPathComponent
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            print("\(name)\tunreadable")
            continue
        }
        guard let state = try? JSONDecoder().decode(PersistedState.self, from: data),
              let written = try? stateEncoder().encode(state) else {
            print("\(name)\tthrow")
            continue
        }
        print("\(name)\t\(canonicalJSON(written) ?? "?")")
    }

case "sync":
    // Golden source for the Kotlin sync layer. Each case file describes one
    // thing to try: read a bundle the other side wrote, produce the file or the
    // QR form, or merge a bundle into a state. The bundle's own JSON is dumped
    // canonically, so a field Kotlin renames or forgets shows up as a diff.
    guard args.count >= 2 else { usage() }
    let dir = URL(fileURLWithPath: args[1], isDirectory: true)
    for name in ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    where name.hasSuffix(".json") {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
              let caseObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = caseObject["kind"] as? String
        else { continue }
        print("=== \(name.dropLast(5))")
        runSyncCase(kind, caseObject)
    }

case "sync-read":
    // The other direction: a file (or a link inside a text file) written by
    // another platform, read back through the Swift decoder.
    guard args.count >= 2 else { usage() }
    for path in args.dropFirst() {
        let name = (path as NSString).lastPathComponent
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            print("\(name)\terror\tunreadable")
            continue
        }
        do {
            print("\(name)\tbundle\t\(bundleDump(try SyncBundle.decode(data)))")
        } catch let error as SyncBundle.DecodeError {
            print("\(name)\terror\t\(syncErrorDump(error))")
        } catch {
            print("\(name)\terror\tdeserialize")
        }
    }

case "score":
    // Golden source for the Kotlin ranker port: one history per line (RTT in ms,
    // −1 = failed probe), and every number the hand-built scores and the kxc
    // feature vector produce. Printed with full precision on purpose — these are
    // floats computed twice, and the last bit is exactly what is worth seeing.
    guard args.count >= 2, let text = try? String(contentsOfFile: args[1], encoding: .utf8) else { usage() }
    for line in text.split(separator: "\n") {
        if line.isEmpty { continue }
        let history = line.split(separator: ",").compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
        let features = KxcFeatures.extract(history)
        print([
            "\(line)",
            "score=" + exact(ServerScoring.rankingScore(history)),
            "avg=" + exact(ServerScoring.averagePing(history)),
            "stability=" + exact(ServerScoring.stability(history)),
            "kxc=" + features.map(exact).joined(separator: " "),
        ].joined(separator: "\t"))
    }

case "ledger":
    // Golden source for the Kotlin traffic ledger. A case file is a script of
    // readings and questions, so the state machine — new run vs. same run,
    // capped step, prune, forget — is compared, not just one call.
    guard args.count >= 2 else { usage() }
    let dir = URL(fileURLWithPath: args[1], isDirectory: true)
    for name in ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    where name.hasSuffix(".txt") {
        guard let text = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) else { continue }
        print("=== \(name.dropLast(4))")
        var ledger = TrafficLedger()
        for raw in text.split(separator: "\n") {
            let parts = raw.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let verb = parts.first else { continue }
            switch verb {
            case "rec":
                // rec  run  recv  sent  id  name  now  tz
                guard parts.count >= 8, let run = number(parts[1]), let now = number(parts[6]) else { continue }
                let id = parts[4] == "-" ? nil : UUID(uuidString: parts[4])
                let server = id.map { (id: $0, name: parts[5]) }
                ledger.record(runStartedAt: Date(timeIntervalSince1970: run),
                              received: Int64(parts[2]) ?? 0, sent: Int64(parts[3]) ?? 0,
                              server: server, at: Date(timeIntervalSince1970: now),
                              timeZone: TimeZone(identifier: parts[7]) ?? .current)
            case "stopped": ledger.stopped()
            case "reset": ledger.reset()
            case "forget":
                ledger.forget(Set(parts.dropFirst().compactMap { UUID(uuidString: $0) }))
            case "days":
                guard parts.count >= 3, let count = Int(parts[1]), let now = number(parts[2]) else { continue }
                for day in ledger.recentDays(count, now: Date(timeIntervalSince1970: now),
                                             timeZone: TimeZone(identifier: parts[3]) ?? .current) {
                    print("day\t" + dayDump(day))
                }
            case "today", "month":
                guard parts.count >= 2, let now = number(parts[1]) else { continue }
                let day = verb == "today"
                    ? ledger.today(now: Date(timeIntervalSince1970: now),
                                   timeZone: TimeZone(identifier: parts[2]) ?? .current)
                    : ledger.month(now: Date(timeIntervalSince1970: now),
                                   timeZone: TimeZone(identifier: parts[2]) ?? .current)
                print("\(verb)\t" + dayDump(day))
            case "top":
                for total in ledger.topServers {
                    print("srv\tid=\(total.id.uuidString) name=\(total.name) recv=\(total.received)" +
                          " sent=\(total.sent) total=\(total.total)" +
                          " lastUsed=\(exact(total.lastUsed.timeIntervalSince1970))")
                }
            case "key":
                guard parts.count >= 3, let now = number(parts[2]) else { continue }
                let zone = TimeZone(identifier: parts[1]) ?? .current
                print("key\t\(TrafficLedger.dayKey(Date(timeIntervalSince1970: now), timeZone: zone))")
            case "dayof":
                guard parts.count >= 3 else { continue }
                let zone = TimeZone(identifier: parts[1]) ?? .current
                let date = TrafficLedger.date(ofDay: parts[2], timeZone: zone)
                print("dayof\t\(date.map { exact($0.timeIntervalSince1970) } ?? "nil")")
            default:
                print("error\tunknown verb \(verb)")
            }
        }
    }

case "leak":
    // Golden source for the Kotlin leak check: the three answers the leak
    // screens parse, and the verdict `findings` reaches about them. Network
    // calls stay out of it — only the parsing and the judgement are portable.
    guard args.count >= 2, let text = try? String(contentsOfFile: args[1], encoding: .utf8) else { usage() }
    for line in text.split(separator: "\n") {
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard let verb = parts.first else { continue }
        switch verb {
        case "ipsb":
            guard let body = field(parts, 1) else { print("error\tipsb: нет тела"); continue }
            print("ipsb\t" + ((try? LeakCheck.parseIPSB(Data(body.utf8))).map(ipInfoDump) ?? "throw"))
        case "trace":
            guard let body = field(parts, 1) else { print("error\ttrace: нет тела"); continue }
            print("trace\t" + ((try? LeakCheck.parseTrace(Data(unescaped(body).utf8)))
                .map(ipInfoDump) ?? "throw"))
        case "bashws":
            guard let body = field(parts, 1) else { print("error\tbashws: нет тела"); continue }
            let servers = (try? LeakCheck.parseBashWS(Data(body.utf8))).map { list in
                list.map { dnsDump($0) }.joined(separator: ";")
            }
            print("bashws\t" + (servers ?? "throw"))
        case "findings":
            // findings  exit  direct  ipv6  dns
            guard field(parts, 4) != nil else { print("error\tfindings: мало полей"); continue }
            let verdicts = LeakCheck.findings(exit: infoField(parts[1]), direct: infoField(parts[2]),
                                              ipv6: infoField(parts[3]), dns: dnsField(parts[4]))
            print("findings\t" + (verdicts.isEmpty ? "чисто" : verdicts.map {
                switch $0 {
                case .tunnelBypassed: "tunnelBypassed"
                case .ipv6Leak(let info): "ipv6Leak(\(ipInfoDump(info)))"
                case .dnsLeak(let list): "dnsLeak(\(list.map(dnsDump).joined(separator: ";")))"
                }
            }.joined(separator: " ")))
        default:
            print("error\tunknown verb \(verb)")
        }
    }

case "probe":
    // The portable half of the latency probe: what one attempt would dial, and
    // how a round of attempts accumulates and gives up on a dead server.
    guard args.count >= 2, let text = try? String(contentsOfFile: args[1], encoding: .utf8) else { usage() }
    for line in text.split(separator: "\n") {
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        switch parts.first {
        case "target":
            guard parts.count >= 5 else { continue }
            let dial = LatencyProbe.target(host: parts[1], port: Int(parts[2]) ?? -1,
                                           sni: parts[3] == "-" ? nil : parts[3], tls: parts[4] == "1")
            print("target\tusable=\(dial.usable ? 1 : 0) port=\(dial.port) " +
                  "sni=\(dial.serverName ?? "-") tls=\(dial.tls ? 1 : 0)")
        case "collect":
            guard parts.count >= 4 else { continue }
            let outcomes = parts[3].split(separator: ",").map { $0 == "-" ? nil : Int($0) }
            guard !outcomes.isEmpty else { print("collect\terror: пустой список исходов"); continue }
            let results = await LatencyProbe.collect(
                count: Int(parts[1]) ?? 0,
                earlyAbortAfterFails: parts[2] == "-" ? nil : Int(parts[2])
            ) { index in outcomes[min(index, outcomes.count - 1)] }
            print("collect\t" + results.map { $0.map(String.init) ?? "—" }.joined(separator: ",") +
                  " всего=\(results.count)")
        default:
            print("error\tunknown verb \(parts.first ?? "")")
        }
    }

case "hysteria":
    // Корпус hysteria-конфигов: валидация и YAML для каждой ссылки, чтобы Kotlin
    // сверял текст дословно, а не «похоже».
    guard args.count >= 2, let text = try? String(contentsOfFile: args[1], encoding: .utf8) else { usage() }
    for line in text.split(separator: "\n") {
        let parts = line.split(separator: "\t").map(String.init)
        guard let first = parts.first, !first.isEmpty else { continue }
        // Ссылка — обычный путь. `server {json}` задаёт сервер напрямую: только
        // так проверяются формы, которые ссылка описать не может (адрес IPv6 без
        // скобок, hopping, не покрывающий порт).
        let port = parts.count > 2 ? (Int(parts[2]) ?? 21180) : 21180
        print("=== \(line)")
        do {
            let server: ProxyServer
            if first == "server" {
                guard let data = parts[1].data(using: .utf8),
                      let decoded = try? JSONDecoder().decode(ProxyServer.self, from: data)
                else { print("error\tbad server json"); continue }
                server = decoded
            } else {
                server = try ShareLinkParser.parse(first)
            }
            for problem in HysteriaConfigBuilder.validate(server: server) {
                print("problem\t\(problem)")
            }
            let yaml = try HysteriaConfigBuilder.makeClientConfig(server: server, socksPort: port)
            print("yaml\t" + Data(yaml.utf8).base64EncodedString())
        } catch {
            print("error\t\(describeParseError(error))")
        }
    }

case "stats":
    // Проволочный формат статистики движка: байты запроса (детерминированы) и
    // разбор ответа. Сеть не участвует.
    guard args.count >= 2, let text = try? String(contentsOfFile: args[1], encoding: .utf8) else { usage() }
    for line in text.split(separator: "\n") {
        let parts = line.split(separator: "\t").map(String.init)
        switch parts.first {
        case "request":
            let portText = field(parts, 1)
            let port: UInt16
            if portText == nil || portText == "" || portText == "-" {
                port = 0
            } else if let parsed = u16Field(portText) {
                port = parsed
            } else {
                print("error\trequest: порт вне 0…65535 — «\(portText ?? "")»")
                continue
            }
            let pattern = parts.count > 2 && parts[2] != "-" ? parts[2] : nil
            let bytes = XrayStatsAPI.requestBytes(port: port, pattern: pattern)
            print("request\t" + bytes.map { String(format: "%02x", $0) }.joined())
        case "header":
            // HPACK-длина с продолжением: короткий префикс ломается именно на
            // 127-й байте, и проверить это можно только длинным значением.
            guard parts.count >= 3 else { continue }
            let bytes = XrayStatsAPI.header(parts[1], parts[2])
            print("header\t" + bytes.map { String(format: "%02x", $0) }.joined())
        case "frame":
            guard parts.count >= 5,
                  let type = u8Field(field(parts, 1), radix: 16),
                  let flags = u8Field(field(parts, 2), radix: 16),
                  let stream = UInt32(parts[3])
            else { continue }
            var payload = Data()
            var index = parts[4] == "none" ? parts[4].endIndex : parts[4].startIndex
            while index < parts[4].endIndex {
                guard let byte = UInt8(parts[4][index...].prefix(2), radix: 16) else { break }
                payload.append(byte)
                index = parts[4].index(index, offsetBy: min(2, parts[4].distance(from: index, to: parts[4].endIndex)))
            }
            let bytes = XrayStatsAPI.frame(type: UInt8(type), flags: UInt8(flags), stream: stream, payload: payload)
            print("frame\t" + bytes.map { String(format: "%02x", $0) }.joined())
        case "framehead":
            // Одна шапка, без полезной нагрузки: так проверяются все три байта
            // 24-битной длины — и кадры больше 64 КБ, которых протокол не шлёт.
            guard parts.count >= 5,
                  let stream = UInt32(parts[3]), let length = Int(parts[4]),
                  let typeByte = u8Field(field(parts, 1), radix: 16),
                  let flagsByte = u8Field(field(parts, 2), radix: 16),
                  length >= 0, length <= 0xFFFFFF   // 24-битная длина кадра и есть потолок
            else { print("framehead\terror: кадр вне диапазона фикстуры"); continue }
            let bytes = XrayStatsAPI.frame(type: typeByte, flags: flagsByte, stream: stream,
                                           payload: Data(count: length))
            print("framehead\t" + bytes.prefix(9).map { String(format: "%02x", $0) }.joined())
        case "parse":
            let hex = parts.count > 1 ? parts[1] : ""
            var bytes: [UInt8] = []
            var index = hex.startIndex
            while index < hex.endIndex {
                guard let byte = UInt8(hex[index...].prefix(2), radix: 16) else { break }
                bytes.append(byte)
                index = hex.index(index, offsetBy: min(2, hex.distance(from: index, to: hex.endIndex)))
            }
            guard hex.count % 2 == 0, bytes.count * 2 == hex.count else { print("parse\tbad hex"); continue }
            let data = Data(bytes)
            let stats = XrayStatsAPI.parseProtobuf(data)
            print("parse\t" + (stats.isEmpty ? "пусто" : stats.map { "\($0.name)=\($0.value)" }.joined(separator: ";")))
        default:
            print("error\tunknown verb \(parts.first ?? "")")
        }
    }

case "mask":
    // Выученное маскирование: ключи (общий и сетевой), что читается при
    // подключении и что остаётся после «забыть».
    guard args.count >= 2, let text = try? String(contentsOfFile: args[1], encoding: .utf8) else { usage() }
    for line in text.split(separator: "\n") {
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard let verb = parts.first, parts.count >= 2 else { continue }
        func server(_ json: String) -> ProxyServer? {
            guard let data = json.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(ProxyServer.self, from: data)
        }
        func kind(_ text: String) -> NetworkKind? { text == "-" ? nil : NetworkKind(rawValue: text) }
        func map(_ state: PersistedState) -> String {
            state.learnedMasking.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ";")
        }
        switch verb {
        case "key":
            guard let s = server(field(parts, 1) ?? ""), let kindText = field(parts, 2)
            else { print("key\tмало полей"); continue }
            print("key\t\(s.identityKey)|\(PersistedState.learnedMaskingKey(for: s, on: kind(kindText)))")
        case "serverkey":
            guard let key = field(parts, 1) else { print("serverkey\tмало полей"); continue }
            print("serverkey\t\(PersistedState.serverKey(ofLearnedMaskingKey: key))")
        case "lookup":
            guard let s = server(field(parts, 1) ?? ""), let kindText = field(parts, 2),
                  let stateText = field(parts, 3)
            else { print("lookup\tмало полей"); continue }
            let state = (try? JSONDecoder().decode(PersistedState.self, from: Data(stateText.utf8))) ?? PersistedState()
            print("lookup\t\(state.learnedMasking(for: s, on: kind(kindText))?.rawValue ?? "-")")
        case "learn":
            guard let stateText = field(parts, 3), let kindText = field(parts, 4),
                  let s = server(field(parts, 1) ?? ""), let profileText = field(parts, 2),
                  var state = try? JSONDecoder().decode(PersistedState.self, from: Data(stateText.utf8))
            else { print("learn\tмало полей или битый json"); continue }
            let profile = profileText == "?" ? nil : MaskingProfile(rawValue: profileText)
            state.learnMasking(profile, for: s, on: kind(kindText))
            print("learn\t\(map(state))")
        default:
            print("error\tunknown verb \(verb)")
        }
    }

case "looks":
    // Распознавание «это наш бандл» — то, по чему шторка импорта решает,
    // показывать предпросмотр или нет.
    guard args.count >= 2, let text = try? String(contentsOfFile: args[1], encoding: .utf8) else { usage() }
    for line in text.split(separator: "\n") {
        let unescaped = unescaped(String(line))
        print("\(unescaped)\t\(SyncBundle.looksLikeBundle(unescaped) ? "да" : "нет")")
    }

case "carry":
    // Перенос id серверов между обновлениями подписки: старые и новые записи
    // задаются identityKey'ами, ответ — какие id достались каждой новой.
    guard args.count >= 2, let text = try? String(contentsOfFile: args[1], encoding: .utf8) else { usage() }
    for line in text.split(separator: "\n") {
        let parts = line.split(separator: "|", omittingEmptySubsequences: true).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard parts.count >= 2 else { continue }
        func server(_ key: String, _ id: String) -> ProxyServer {
            var s = ProxyServer(name: key, proto: .vless, address: key, port: 443, credential: key)
            s.id = UUID(uuidString: id) ?? UUID()
            return s
        }
        // Имена и id в фикстуре всегда явные: случайный id сделал бы эталон
        // разным на двух прогонах.
        func list(_ text: String) -> [ProxyServer] {
            text.split(separator: ",").compactMap { pair in
                let bits = pair.split(separator: "=")
                guard bits.count == 2, UUID(uuidString: String(bits[1])) != nil else { return nil }
                return server(String(bits[0]), String(bits[1]))
            }
        }
        let old = list(parts[0])
        let fresh = list(parts[1])
        let carried = SubscriptionParser.carryingIDs(from: old, into: fresh)
        print("\(line)\t" + carried.map { $0.id.uuidString }.joined(separator: ","))
    }

case "number":
    // Golden-источник для Kotlin-порта `SwiftDouble`: Foundation's `Double(_:)`
    // — это strtod, а не JSON-число и не «пробелы вокруг нормальны». Кейсы в
    // фикстуре лежат hex'ом (в строке не передать , NBSP или перенос), а
    // ответ печатается битом IEEE-754, чтобы знак нуля и nan не прятались в
    // десятичном виде.
    guard args.count >= 2, let text = try? String(contentsOfFile: args[1], encoding: .utf8) else { usage() }
    for line in text.components(separatedBy: "\n") {
        if line.isEmpty { continue }
        guard let data = hexBytes(line) else {
            print("\(line)\tbad hex\tbad hex")
            continue
        }
        let input = String(decoding: data, as: UTF8.self)
        let verdict: String
        if let value = Double(input) {
            if value.isNaN {
                verdict = "nan"
            } else if value == .infinity {
                verdict = "inf"
            } else if value == -.infinity {
                verdict = "-inf"
            } else {
                verdict = String(format: "%016llx", value.bitPattern)
            }
        } else {
            verdict = "nil"
        }
        // Та же фикстура прогоняется и через `Int(String)`: тот же класс
        // расхождений (Java переводит «1٠» в 10, Foundation — нет), и свой
        // набор краёв.
        let intVerdict = Int(input).map(String.init) ?? "nil"
        print("\(line)\t\(verdict)\t\(intVerdict)")
    }

case "b64":
    // Golden source for the Kotlin `Base64.decodeFlexible`: every input, hex or
    // `nil`. Flexible base64 is where a hand-written decoder quietly diverges
    // from Foundation, so the whole table is compared, not a sample.
    guard args.count >= 2, let text = try? String(contentsOfFile: args[1], encoding: .utf8) else { usage() }
    for line in text.components(separatedBy: "\n") {
        if line.isEmpty { continue }
        let hex = Base64.decodeFlexible(line)
            .map { data in data.map { String(format: "%02x", $0) }.joined() } ?? "nil"
        print("\(line)\t\(hex)")
    }

default:
    usage()
}
