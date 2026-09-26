import SwiftUI
import LoaderCore

/// Leak Test: the address sites see, whether IPv6 and DNS stay inside the
/// VPN, and for comparison the provider's own address.
struct LeakTestSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            LeakTestContent(test: state.leakTest)
                .background(GroundBackground())
                .navigationTitle("Leak Test")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                            .keyboardShortcut(.cancelAction)
                    }
                }
        }
        .frame(width: 500, height: 600)
    }
}

private struct LeakTestContent: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var test: LeakTestModel

    private var server: UUID? {
        state.isConnected ? state.sessionServerID : nil
    }

    var body: some View {
        Form {
            Section {
                summary
            }

            if let report = test.report {
                Section("Sites See") {
                    if let exit = report.exit {
                        AddressRow(info: exit)
                    } else {
                        Text("The address check didn't answer")
                            .foregroundStyle(Theme.textLo)
                    }
                }

                if report.serverID != nil, report.exit != nil {
                    Section {
                        tunnelRow(report)
                        ipv6Row(report)
                        dnsRow(report)
                    } header: {
                        Text("Checks")
                    } footer: {
                        if report.socksOnly {
                            Text("Proxy-only mode: apps that don't use the SOCKS proxy go around the VPN. Install the helper (Settings → Network) for the full tunnel.")
                                .foregroundStyle(Theme.textLo)
                        }
                    }
                }

                if let servers = report.dns, !servers.isEmpty {
                    Section {
                        ForEach(ResolverGroup.of(servers, leaking: report.dnsLeak)) { group in
                            ResolverRow(group: group)
                        }
                    } header: {
                        Text("DNS Servers")
                    } footer: {
                        Text("They answer this Mac's lookups. Resolvers in your own country let your provider see which sites you open.")
                            .foregroundStyle(Theme.textLo)
                    }
                }

                if report.serverID != nil, let direct = report.direct {
                    Section {
                        AddressRow(info: direct)
                    } header: {
                        Text("Without the VPN")
                    } footer: {
                        Text("Your provider's address — what sites would see without the VPN. Asked over the physical network interface, around the tunnel.")
                            .foregroundStyle(Theme.textLo)
                    }
                }
            }

            Section {
                HStack {
                    Text("Addresses come from ip.sb, DNS servers from bash.ws: for the test they see the exit address and a few test lookups.")
                        .font(.caption)
                        .foregroundStyle(Theme.textLo)
                    Spacer(minLength: 12)
                    Button {
                        Task { await test.run(server: server, proxy: state.appProxy) }
                    } label: {
                        Label("Test Again", systemImage: "arrow.clockwise")
                    }
                    .nativeButtonStyle()
                    .disabled(test.isRunning || state.connection == .connecting)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .task {
            if !test.isCurrent(server: server), state.connection != .connecting {
                await test.run(server: server, proxy: state.appProxy)
            }
        }
    }

    // MARK: - Summary

    private var summary: some View {
        HStack(spacing: 14) {
            ZStack {
                if test.isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: look.symbol)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(look.filled ? Color.white : Theme.textLo)
                }
            }
            .frame(width: 44, height: 44)
            .background(look.filled && !test.isRunning ? AnyShapeStyle(Theme.accent.gradient) : AnyShapeStyle(Theme.idle),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(look.title)
                    .font(.system(size: 20, weight: .medium, design: .serif))
                    .foregroundStyle(Theme.textHi)
                Text(look.detail)
                    .font(.callout)
                    .foregroundStyle(Theme.textLo)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private var look: (symbol: String, filled: Bool, title: String, detail: String) {
        if let step = test.step {
            return ("magnifyingglass", false, "Testing…", step)
        }
        guard let report = test.report else {
            return ("questionmark.circle", false, "Not tested", "Click Test Again to run the test.")
        }
        switch report.verdict {
        case .clean:
            return ("checkmark.shield.fill", true, "No leaks",
                    "Sites see the server's address, and neither DNS nor IPv6 gives yours away.")
        case .leaks:
            return ("exclamationmark.shield.fill", true, "Leaks found", leakSummary(report))
        case .unknown:
            return ("shield.lefthalf.filled", true, "Address hidden",
                    "Couldn't compare with your own address — with the kill switch armed nothing may leave around the tunnel, this test included.")
        case .unprotected:
            return ("shield.slash", false, "Not connected",
                    "Sites see your real address. Connect, then test again.")
        case .failed:
            return ("exclamationmark.triangle.fill", false, "Test failed",
                    "ip.sb didn't answer — check the connection.")
        }
    }

    private func leakSummary(_ report: LeakTestModel.Report) -> String {
        var parts: [String] = []
        if report.bypassed { parts.append("traffic goes around the VPN") }
        if report.ipv6Leak != nil { parts.append("IPv6 gives your address away") }
        if !report.dnsLeak.isEmpty { parts.append("your provider sees DNS lookups") }
        let text = parts.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst() + "."
    }

    // MARK: - Checks

    private func tunnelRow(_ report: LeakTestModel.Report) -> some View {
        let result: CheckState = report.direct == nil ? .unknown : (report.bypassed ? .failed : .passed)
        let caption = switch result {
        case .passed: "The exit address isn't yours"
        case .failed: "Sites see your real address"
        case .unknown: "Nothing to compare with"
        }
        return CheckRow(symbol: "arrow.triangle.merge", title: "Traffic through the VPN", caption: caption, state: result)
    }

    private func ipv6Row(_ report: LeakTestModel.Report) -> some View {
        if let leak = report.ipv6Leak {
            return CheckRow(symbol: "6.circle.fill", title: "IPv6", caption: "Goes around the VPN: \(leak.ip)", state: .failed)
        }
        if let ipv6 = report.ipv6 {
            return CheckRow(symbol: "6.circle.fill", title: "IPv6", caption: "Through the VPN: \(ipv6.ip)", state: .passed)
        }
        return CheckRow(symbol: "6.circle.fill", title: "IPv6", caption: "Not in use — nothing to leak", state: .passed)
    }

    private func dnsRow(_ report: LeakTestModel.Report) -> some View {
        guard let servers = report.dns else {
            return CheckRow(symbol: "text.magnifyingglass", title: "DNS", caption: "The DNS test didn't answer", state: .unknown)
        }
        let leaking = report.dnsLeak.count
        if leaking > 0 {
            return CheckRow(symbol: "text.magnifyingglass", title: "DNS",
                            caption: "\(leaking) resolver\(leaking == 1 ? "" : "s") in your country", state: .failed)
        }
        let caption = servers.isEmpty ? "No lookups reached the test" : "Lookups go through the VPN"
        return CheckRow(symbol: "text.magnifyingglass", title: "DNS", caption: caption,
                        state: report.direct == nil || servers.isEmpty ? .unknown : .passed)
    }
}

private enum CheckState {
    case passed, failed, unknown
}

/// One check: a glyph tile that fills with clay when it passed, the verdict
/// trailing.
private struct CheckRow: View {
    let symbol: String
    let title: String
    let caption: String
    let state: CheckState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(state == .passed ? Color.white : Theme.textLo)
                .frame(width: 24, height: 24)
                .background(state == .passed ? AnyShapeStyle(Theme.accent.gradient) : AnyShapeStyle(Theme.idle),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(Theme.textHi)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(state == .failed ? Theme.accent : Theme.textLo)
            }
            Spacer(minLength: 8)
            Image(systemName: verdictSymbol)
                .foregroundStyle(state == .failed ? Theme.accent : (state == .passed ? Theme.textHi : Theme.textLo))
        }
        .accessibilityElement(children: .combine)
    }

    private var verdictSymbol: String {
        switch state {
        case .passed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .unknown: "questionmark.circle"
        }
    }
}

/// An address with where it is and whose it is.
private struct AddressRow: View {
    let info: LeakCheck.IPInfo

    var body: some View {
        HStack(spacing: 10) {
            Text(info.countryCode.map(flag) ?? "🌐")
                .font(.system(size: 20))
            VStack(alignment: .leading, spacing: 2) {
                Text(info.ip)
                    .font(.body.monospaced())
                    .foregroundStyle(Theme.textHi)
                    .textSelection(.enabled)
                if !place.isEmpty {
                    Text(place)
                        .font(.caption)
                        .foregroundStyle(Theme.textLo)
                }
            }
        }
    }

    private var place: String {
        let country = info.countryCode.flatMap { Locale.current.localizedString(forRegionCode: $0) } ?? info.country
        return [country, info.city, info.isp].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
    }
}

/// Resolvers of one operator in one country: big ones answer from a dozen
/// addresses, which say nothing more one by one.
private struct ResolverGroup: Identifiable {
    var countryCode: String?
    var country: String?
    var org: String?
    var addresses: [String] = []
    var leaking = false

    var id: String { (countryCode ?? "") + "|" + (org ?? addresses.first ?? "") }

    static func of(_ servers: [LeakCheck.DNSServer], leaking: [LeakCheck.DNSServer]) -> [ResolverGroup] {
        var groups: [ResolverGroup] = []
        for server in servers {
            let index = groups.firstIndex { $0.countryCode == server.countryCode && $0.org == server.org && server.org != nil }
                ?? {
                    groups.append(ResolverGroup(countryCode: server.countryCode, country: server.country, org: server.org))
                    return groups.count - 1
                }()
            groups[index].addresses.append(server.ip)
            if leaking.contains(server) { groups[index].leaking = true }
        }
        return groups
    }
}

private struct ResolverRow: View {
    let group: ResolverGroup

    var body: some View {
        HStack(spacing: 10) {
            Text(group.countryCode.map(flag) ?? "🌐")
                .font(.system(size: 18))
            VStack(alignment: .leading, spacing: 2) {
                Text(group.org ?? group.addresses.first ?? "")
                    .foregroundStyle(Theme.textHi)
                    .lineLimit(1)
                Text(caption)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(group.leaking ? Theme.accent : Theme.textLo)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            if group.leaking {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.accent)
                    .help("In your country")
            }
        }
    }

    private var caption: String {
        let country = group.countryCode.flatMap { Locale.current.localizedString(forRegionCode: $0) } ?? group.country
        var addresses = group.addresses.first ?? ""
        if group.addresses.count > 1 { addresses += " and \(group.addresses.count - 1) more" }
        return [country, group.org == nil ? nil : addresses].compactMap { $0 }.joined(separator: " · ")
    }
}

/// 🇫🇷 from "FR".
private func flag(_ code: String) -> String {
    String(code.uppercased().unicodeScalars.compactMap { scalar in
        (65...90).contains(scalar.value) ? UnicodeScalar(0x1F1E6 - 65 + scalar.value).map(Character.init) : nil
    })
}
