import Charts
import SwiftUI
import LoaderCore

/// Statistics: what went through the VPN (today, this month, two weeks,
/// which servers carried it) and a speed test through the connection.
struct StatsSheet: View {
    enum Pane: Hashable {
        case usage, speed
    }

    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var pane: Pane

    init(pane: Pane = .usage) {
        _pane = State(initialValue: pane)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch pane {
                case .usage: UsagePane(usage: state.usage)
                case .speed: SpeedPane(test: state.speedTest)
                }
            }
            .background(GroundBackground())
            .navigationTitle(pane == .usage ? "Statistics" : "Speed Test")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Pane", selection: $pane) {
                        Text("Usage").tag(Pane.usage)
                        Text("Speed Test").tag(Pane.speed)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .frame(width: 540, height: 600)
    }
}

// MARK: - Usage

private struct UsagePane: View {
    @ObservedObject var usage: UsageStats
    @State private var confirmingReset = false

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 16) {
                    summary("Today", usage.today)
                    Divider()
                    summary("This Month", usage.month)
                }
                .padding(.vertical, 4)
            }

            Section {
                chart
                    .frame(height: 190)
                    .padding(.vertical, 6)
            } header: {
                Text("Last Two Weeks")
            } footer: {
                Text("Traffic through the VPN while Anemia ran.")
                    .foregroundStyle(Theme.textLo)
            }

            if !usage.topServers.isEmpty {
                Section("Servers") {
                    ForEach(usage.topServers.prefix(8)) { server in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.name)
                                    .foregroundStyle(Theme.textHi)
                                    .lineLimit(1)
                                Text("↓ \(Format.bytes(server.received)) · ↑ \(Format.bytes(server.sent))")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(Theme.textLo)
                            }
                            Spacer(minLength: 8)
                            Text(Format.bytes(server.total))
                                .font(.callout.monospacedDigit().weight(.medium))
                                .foregroundStyle(Theme.textHi)
                        }
                    }
                }
            }

            Section {
                Button("Reset Statistics…", role: .destructive) { confirmingReset = true }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .confirmationDialog("Reset all traffic statistics?", isPresented: $confirmingReset) {
            Button("Reset", role: .destructive) { usage.reset() }
        }
    }

    private func summary(_ title: String, _ day: TrafficLedger.Day) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(Theme.textLo)
            Text(Format.bytes(day.total))
                .font(.system(size: 24, weight: .medium, design: .serif))
                .foregroundStyle(Theme.textHi)
            Text("↓ \(Format.bytes(day.received)) · ↑ \(Format.bytes(day.sent))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.textLo)
            if day.time >= 60 {
                Text("\(Format.span(day.time)) connected")
                    .font(.caption)
                    .foregroundStyle(Theme.textLo)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var chart: some View {
        let days = usage.recentDays(14)
        return Chart {
            ForEach(days) { day in
                BarMark(x: .value("Day", day.date, unit: .day),
                        y: .value("MB", Double(day.received) / 1_048_576))
                    .foregroundStyle(by: .value("Direction", "Download"))
                BarMark(x: .value("Day", day.date, unit: .day),
                        y: .value("MB", Double(day.sent) / 1_048_576))
                    .foregroundStyle(by: .value("Direction", "Upload"))
            }
        }
        .chartForegroundStyleScale(["Download": Theme.accent, "Upload": Theme.textLo.opacity(0.55)])
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 3)) { _ in
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(Theme.stroke)
                AxisValueLabel {
                    if let megabytes = value.as(Double.self) {
                        Text(Format.bytes(Int64(megabytes * 1_048_576)))
                    }
                }
            }
        }
        .chartLegend(position: .bottom, alignment: .leading)
    }
}

// MARK: - Speed test

private struct SpeedPane: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var test: SpeedTestModel

    var body: some View {
        Form {
            Section {
                VStack(spacing: 14) {
                    gauge
                    HStack(spacing: 0) {
                        metric("Download", value: test.download.map(Format.bitRate), active: test.phase == .download)
                        metric("Upload", value: test.upload.map(Format.bitRate), active: test.phase == .upload)
                        metric("Latency", value: test.latency.map { Format.ping($0) }, active: test.phase == .latency)
                    }
                    Text(route)
                        .font(.caption)
                        .foregroundStyle(Theme.textLo)
                    Button {
                        Task { await test.run(through: routeServer, proxy: state.appProxy) }
                    } label: {
                        Text(test.phase == .done ? "Run Again" : "Start")
                            .frame(minWidth: 160)
                    }
                    .controlSize(.large)
                    .nativeButtonStyle(prominent: true)
                    .disabled(test.isRunning || state.connection == .connecting)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } footer: {
                if case .failed(let reason) = test.phase {
                    Text(reason)
                        .foregroundStyle(Theme.accent)
                } else {
                    Text("Measured against Cloudflare's speed servers: up to 10 seconds each way and at most 225 MB of traffic.")
                        .foregroundStyle(Theme.textLo)
                }
            }

            if !test.history.isEmpty {
                Section("Earlier Tests") {
                    ForEach(test.history) { result in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("↓ \(Format.bitRate(result.download))" + (result.upload.map { " · ↑ \(Format.bitRate($0))" } ?? ""))
                                    .font(.callout.monospacedDigit())
                                    .foregroundStyle(Theme.textHi)
                                Text(result.server ?? "Without the VPN")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textLo)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            VStack(alignment: .trailing, spacing: 2) {
                                if let latency = result.latency {
                                    Text(Format.ping(latency))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(Theme.textHi)
                                }
                                Text(result.date, format: .dateTime.day().month(.abbreviated).hour().minute())
                                    .font(.caption)
                                    .foregroundStyle(Theme.textLo)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    /// The server the test goes through; nil without the VPN.
    private var routeServer: String? {
        state.isConnected ? state.sessionServer?.name : nil
    }

    private var route: String {
        guard let server = routeServer else { return "Without the VPN — straight from this Mac" }
        return state.appProxy == nil ? "Through \(server)" : "Through \(server), via the engine's SOCKS port"
    }

    /// The live rate on a half ring, scaled to the nearest round ceiling.
    private var gauge: some View {
        let value = test.isRunning ? test.live : (test.download ?? 0)
        let ceiling = [10e6, 25e6, 50e6, 100e6, 250e6, 500e6, 1e9].first { value <= $0 } ?? 1e9
        let fraction = min(value / ceiling, 1)
        let parts = Format.bitRate(value).split(separator: " ", maxSplits: 1).map(String.init)
        return ZStack {
            Circle()
                .trim(from: 0.12, to: 0.88)
                .stroke(Theme.idle, style: StrokeStyle(lineWidth: 11, lineCap: .round))
                .rotationEffect(.degrees(90))
            Circle()
                .trim(from: 0.12, to: 0.12 + 0.76 * fraction)
                .stroke(Theme.accent.gradient, style: StrokeStyle(lineWidth: 11, lineCap: .round))
                .rotationEffect(.degrees(90))
                .animation(.easeOut(duration: 0.25), value: fraction)
            VStack(spacing: 0) {
                Text(parts.first ?? "0")
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(Theme.textHi)
                Text(phaseText.isEmpty ? (parts.count > 1 ? parts[1] : "Mbps") : phaseText)
                    .font(.footnote)
                    .foregroundStyle(Theme.textLo)
            }
        }
        .frame(width: 180, height: 180)
        .accessibilityElement(children: .combine)
    }

    private var phaseText: String {
        switch test.phase {
        case .latency: "latency…"
        case .download: "download"
        case .upload: "upload"
        default: ""
        }
    }

    private func metric(_ title: String, value: String?, active: Bool) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(active ? Theme.accent : Theme.textLo)
            Text(value ?? "—")
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(Theme.textHi)
        }
        .frame(maxWidth: .infinity)
    }
}
