import Charts
import LoaderCore
import SwiftUI

/// Traffic through the VPN: today, this month, the last two weeks as a
/// chart, and which servers carried it.
struct StatsView: View {
    @Environment(TrafficStats.self) private var stats
    @Environment(ServerStore.self) private var store
    @State private var confirmingReset = false

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    summary("Сегодня", stats.today)
                    Divider()
                    summary("Этот месяц", stats.month)
                }
                .padding(.vertical, 4)
            }
            .listRowBackground(Theme.card)

            Section {
                chart
                    .frame(height: 180)
                    .padding(.vertical, 8)
            } header: {
                Text("Две недели")
            } footer: {
                Text("Считается трафик, который прошёл через VPN, пока Anemia работала — в фоне тоже, если включена «Скорость в фоне».")
            }
            .listRowBackground(Theme.card)

            if !stats.topServers.isEmpty {
                Section("Серверы") {
                    ForEach(stats.topServers.prefix(8)) { server in
                        HStack(spacing: 10) {
                            FlagBadge(code: Country.code(inServerName: server.name), size: 18)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(server.name)
                                    .foregroundStyle(Theme.ink)
                                    .lineLimit(1)
                                Text("↓ \(Bytes.text(server.received)) · ↑ \(Bytes.text(server.sent))")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(Theme.inkSoft)
                            }
                            Spacer(minLength: 8)
                            Text(Bytes.text(server.total))
                                .font(.footnote.monospacedDigit().weight(.medium))
                                .foregroundStyle(Theme.ink)
                        }
                    }
                }
                .listRowBackground(Theme.card)
            }

            Section {
                Button("Сбросить статистику", role: .destructive) {
                    confirmingReset = true
                }
            }
            .listRowBackground(Theme.card)
        }
        .anemiaList()
        .navigationTitle("Статистика")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Сбросить всю статистику трафика?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Сбросить", role: .destructive) { stats.reset() }
        }
    }

    private func summary(_ title: String, _ day: TrafficLedger.Day) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(Theme.inkSoft)
            Text(Bytes.text(day.total))
                .font(.system(size: 24, weight: .semibold, design: .serif))
                .foregroundStyle(Theme.ink)
            Text("↓ \(Bytes.text(day.received)) · ↑ \(Bytes.text(day.sent))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Theme.inkSoft)
            if day.time >= 60 {
                Text("в сети \(SessionLength.text(day.time))")
                    .font(.caption2)
                    .foregroundStyle(Theme.inkSoft)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var chart: some View {
        let days = stats.recentDays(14)
        return Chart {
            ForEach(days) { day in
                BarMark(x: .value("День", day.date, unit: .day),
                        y: .value("МБ", Double(day.received) / 1_000_000))
                    .foregroundStyle(by: .value("Направление", "Загрузка"))
                BarMark(x: .value("День", day.date, unit: .day),
                        y: .value("МБ", Double(day.sent) / 1_000_000))
                    .foregroundStyle(by: .value("Направление", "Отдача"))
            }
        }
        .chartForegroundStyleScale(["Загрузка": Theme.accent, "Отдача": Theme.inkSoft.opacity(0.55)])
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 3)) { _ in
                AxisValueLabel(format: .dateTime.day().month(.abbreviated).locale(Locale(identifier: "ru_RU")))
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(Theme.stroke)
                AxisValueLabel {
                    if let megabytes = value.as(Double.self) {
                        Text(Bytes.text(Int64(megabytes * 1_000_000)))
                    }
                }
            }
        }
        .chartLegend(position: .bottom, alignment: .leading)
    }
}

/// Download, upload and latency through the current connection.
struct SpeedTestView: View {
    @Environment(SpeedTest.self) private var test
    @Environment(TunnelController.self) private var tunnel
    @Environment(ServerStore.self) private var store

    var body: some View {
        List {
            Section {
                VStack(spacing: 14) {
                    gauge
                    HStack(spacing: 0) {
                        metric("Загрузка", value: test.download.map(Speed.text), active: test.phase == .download)
                        metric("Отдача", value: test.upload.map(Speed.text), active: test.phase == .upload)
                        metric("Пинг", value: test.latency.map { "\($0) мс" }, active: test.phase == .latency)
                    }
                    Text(route)
                        .font(.caption)
                        .foregroundStyle(Theme.inkSoft)
                    if test.isRunning {
                        Button {
                            test.stop()
                        } label: {
                            Text("Остановить")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                        .controlSize(.large)
                        .nativeButtonStyle()
                    } else {
                        Button {
                            test.start()
                        } label: {
                            Text(test.phase == .done ? "Ещё раз" : "Начать")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                        .controlSize(.large)
                        .nativeButtonStyle(prominent: true)
                    }
                }
                .padding(.vertical, 10)
            } footer: {
                if case .failed(let reason) = test.phase {
                    Text(reason)
                        .foregroundStyle(Theme.accent)
                } else {
                    Text("Замер идёт через серверы Cloudflare, до 10 секунд в каждую сторону, и расходует не больше 225 МБ трафика.")
                }
            }
            .listRowBackground(Theme.card)

            if !test.history.isEmpty {
                Section("Прошлые замеры") {
                    ForEach(test.history) { result in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(result.server ?? "Без VPN")
                                    .foregroundStyle(Theme.ink)
                                    .lineLimit(1)
                                Text(result.date.formatted(.relative(presentation: .named).locale(Locale(identifier: "ru_RU"))))
                                    .font(.caption)
                                    .foregroundStyle(Theme.inkSoft)
                            }
                            Spacer(minLength: 8)
                            VStack(alignment: .trailing, spacing: 1) {
                                Text("↓ \(Speed.text(result.download))")
                                    .font(.footnote.monospacedDigit().weight(.medium))
                                    .foregroundStyle(Theme.ink)
                                Text([result.upload.map { "↑ \(Speed.text($0))" }, result.latency.map { "\($0) мс" }]
                                        .compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(Theme.inkSoft)
                            }
                        }
                    }
                }
                .listRowBackground(Theme.card)
            }
        }
        .anemiaList()
        .onDisappear {
            // Замер живёт в модели, а не в `.task` этого экрана: без остановки
            // он доходил до своих 225 МБ уже после того, как пользователь ушёл
            // (кнопка «Остановить» для этого и появилась).
            test.stop()
        }
        .navigationTitle("Тест скорости")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The live rate on a half ring, scaled to the nearest round ceiling.
    private var gauge: some View {
        let value = test.isRunning ? test.live : (test.download ?? 0)
        let ceiling = [10e6, 25e6, 50e6, 100e6, 250e6, 500e6, 1e9].first { value <= $0 } ?? 1e9
        let fraction = min(value / ceiling, 1)
        let parts = Speed.parts(value)
        return ZStack {
            Circle()
                .trim(from: 0.12, to: 0.88)
                .stroke(Theme.idle, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(90))
            Circle()
                .trim(from: 0.12, to: 0.12 + 0.76 * fraction)
                .stroke(Theme.accent.gradient, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(90))
                .animation(.easeOut(duration: 0.25), value: fraction)
            VStack(spacing: 0) {
                Text(parts.value)
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(Theme.ink)
                Text(phaseText.isEmpty ? parts.unit : phaseText)
                    .font(.footnote)
                    .foregroundStyle(Theme.inkSoft)
            }
        }
        .frame(width: 200, height: 200)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var phaseText: String {
        switch test.phase {
        case .latency: "пинг…"
        case .download: "загрузка · " + Speed.parts(test.live).unit
        case .upload: "отдача · " + Speed.parts(test.live).unit
        default: ""
        }
    }

    private func metric(_ title: String, value: String?, active: Bool) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(active ? Theme.accent : Theme.inkSoft)
            Text(value ?? "—")
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(Theme.ink)
        }
        .frame(maxWidth: .infinity)
    }

    private var activeServerName: String? {
        tunnel.activeServerID.flatMap { store.state.server(withID: $0) }?.name
    }

    private var route: String {
        if tunnel.status == .connected, let name = activeServerName { return "Через VPN · \(name)" }
        return "Без VPN — напрямую"
    }
}

