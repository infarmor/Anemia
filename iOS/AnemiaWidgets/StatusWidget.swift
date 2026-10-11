import SwiftUI
import WidgetKit

/// Home Screen and Lock Screen: whether the VPN is on, where it exits, and a
/// button to switch it. The on/off state is checked live; the rest is what
/// the app last wrote to the shared store.
struct StatusWidget: Widget {
    static let kind = WidgetKinds.status

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: StatusProvider()) { entry in
            StatusWidgetView(entry: entry)
                .containerBackground(WidgetPalette.ground, for: .widget)
                .widgetURL(URL(string: "anemia://open"))
        }
        .configurationDisplayName("Anemia")
        .description("Состояние VPN и кнопка включения.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct StatusEntry: TimelineEntry {
    let date: Date
    let isOn: Bool
    let snapshot: WidgetSnapshot

    static let sample = StatusEntry(
        date: .now, isOn: true,
        snapshot: WidgetSnapshot(isOn: true, connected: true, countryCode: "NL", title: "Нидерланды",
                                 subtitle: "Амстердам · VLESS · Reality",
                                 connectedSince: .now.addingTimeInterval(-3_725), latency: 48,
                                 received: 1_240_000_000, sent: 86_000_000, updatedAt: .now)
    )
}

struct StatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatusEntry { .sample }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        if context.isPreview {
            completion(.sample)
            return
        }
        Task { completion(await current()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        Task {
            let entry = await current()
            // The app reloads the widget on every change; this is the backstop.
            completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(15 * 60))))
        }
    }

    private func current() async -> StatusEntry {
        let probe = await VPNProbe.state()
        var snapshot = SharedStore.read() ?? .empty
        // The tunnel as it is now beats the app's last note: the app may have
        // been asleep while iOS brought the VPN up. What the app wrote about
        // the *previous* session goes with the state it was written for, or
        // the clock counts from a session that ended hours ago.
        if snapshot.connected != probe.connected {
            snapshot.connectedSince = nil
            snapshot.latency = nil
        }
        snapshot.connected = probe.connected
        return StatusEntry(date: .now, isOn: probe.on, snapshot: snapshot)
    }
}

/// Claude's palette, following the system appearance.
enum WidgetPalette {
    static let ground = Color(light: 0xFAF9F5, dark: 0x262624)
    static let card = Color(light: 0xF0EEE6, dark: 0x30302E)
    static let ink = Color(light: 0x141413, dark: 0xFAF9F5)
    static let soft = Color(light: 0x6B6A64, dark: 0xA6A39B)
    static let clay = Color(light: 0xC6613F, dark: 0xD97757)
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255,
                           blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
        })
    }
}

struct StatusWidgetView: View {
    let entry: StatusEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemMedium: medium
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        case .accessoryInline: inline
        default: small
        }
    }

    private var snapshot: WidgetSnapshot { entry.snapshot }

    // MARK: Home Screen

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                brand
                Spacer()
                shield(size: 15)
            }
            Spacer(minLength: 6)
            flag(size: 30)
            Text(snapshot.title)
                .font(.system(size: 19, weight: .semibold, design: .serif))
                .foregroundStyle(WidgetPalette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            HStack(alignment: .center, spacing: 6) {
                statusLine
                    .font(.caption.weight(.medium).monospacedDigit())
                Spacer(minLength: 4)
                toggleButton(compact: true)
            }
            .padding(.top, 4)
        }
    }

    private var medium: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                brand
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    flag(size: 26)
                        .frame(width: 44, height: 44)
                        .background(WidgetPalette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(snapshot.title)
                            .font(.system(size: 20, weight: .semibold, design: .serif))
                            .foregroundStyle(WidgetPalette.ink)
                        Text(snapshot.subtitle)
                            .font(.caption)
                            .foregroundStyle(WidgetPalette.soft)
                    }
                    .lineLimit(1)
                }
                statusLine
                    .font(.footnote.weight(.medium).monospacedDigit())
            }
            Spacer(minLength: 0)
            toggleButton(compact: false)
        }
    }

    private var brand: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(entry.isOn ? WidgetPalette.clay : WidgetPalette.soft)
                .frame(width: 6, height: 6)
            Text("Anemia")
                .font(.system(size: 13, weight: .semibold, design: .serif))
                .foregroundStyle(WidgetPalette.ink)
        }
    }

    @ViewBuilder private func flag(size: CGFloat) -> some View {
        if let code = snapshot.countryCode {
            Text(Country.flag(code))
                .font(.system(size: size))
        } else {
            Image(systemName: "globe.europe.africa.fill")
                .font(.system(size: size * 0.85))
                .foregroundStyle(WidgetPalette.clay)
        }
    }

    private func shield(size: CGFloat) -> some View {
        Image(systemName: entry.isOn ? "lock.shield.fill" : "shield.slash")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(entry.isOn ? WidgetPalette.clay : WidgetPalette.soft)
    }

    /// "1:12:04 · 48 мс" while on, "Выключен" otherwise.
    @ViewBuilder private var statusLine: some View {
        if entry.isOn, snapshot.connected, let since = snapshot.connectedSince {
            HStack(spacing: 4) {
                if let latency = snapshot.latency {
                    Text("\(latency) мс ·")
                        .foregroundStyle(WidgetPalette.soft)
                }
                SessionClock(start: since)
                    .foregroundStyle(WidgetPalette.clay)
            }
            .lineLimit(1)
        } else if entry.isOn, snapshot.connected {
            // Up, but the app never told us when it started.
            Text("Включён")
                .foregroundStyle(WidgetPalette.clay)
        } else if entry.isOn {
            Text("Подключение…")
                .foregroundStyle(WidgetPalette.clay)
        } else {
            Text("Выключен")
                .foregroundStyle(WidgetPalette.soft)
        }
    }

    @ViewBuilder private func toggleButton(compact: Bool) -> some View {
        if entry.isOn {
            Button(intent: DisconnectIntent()) {
                buttonLabel(compact: compact, title: "Отключить", symbol: "power", prominent: false)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Отключить VPN")
        } else {
            Button(intent: ConnectIntent()) {
                buttonLabel(compact: compact, title: "Включить", symbol: "power", prominent: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Включить VPN")
        }
    }

    @ViewBuilder
    private func buttonLabel(compact: Bool, title: String, symbol: String, prominent: Bool) -> some View {
        let foreground = prominent ? Color.white : WidgetPalette.clay
        let background = prominent ? WidgetPalette.clay : WidgetPalette.clay.opacity(0.16)
        if compact {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(foreground)
                .frame(width: 34, height: 34)
                .background(background, in: Circle())
        } else {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .bold))
                Text(title)
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(foreground)
            .frame(width: 88, height: 88)
            .background(background, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }

    // MARK: Lock Screen

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            Image(systemName: entry.isOn ? "lock.shield.fill" : "shield.slash")
                .font(.system(size: 22, weight: .semibold))
        }
        .widgetAccentable()
        .accessibilityLabel(entry.isOn ? "VPN включён" : "VPN выключен")
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: entry.isOn ? "lock.shield.fill" : "shield.slash")
                Text("Anemia")
                    .font(.headline)
            }
            .widgetAccentable()
            Text(entry.isOn ? snapshot.title : "Выключен")
                .font(.body)
                .lineLimit(1)
            if entry.isOn, snapshot.connected, let since = snapshot.connectedSince {
                SessionClock(start: since)
                    .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var inline: some View {
        Label(entry.isOn ? "Anemia: \(snapshot.title)" : "Anemia выключен",
              systemImage: entry.isOn ? "lock.shield.fill" : "shield.slash")
    }
}

#Preview("Маленький", as: .systemSmall) {
    StatusWidget()
} timeline: {
    StatusEntry.sample
    StatusEntry(date: .now, isOn: false, snapshot: .empty)
}

#Preview("Средний", as: .systemMedium) {
    StatusWidget()
} timeline: {
    StatusEntry.sample
}
