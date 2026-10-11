import LoaderCore
import SwiftUI

/// The app's mark: the clay glyph beside the name in the headline serif.
struct BrandMark: View {
    var body: some View {
        HStack(spacing: 6) {
            Image("AnemiaMark")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(height: 20)
                .foregroundStyle(Theme.accent)
            Text("Anemia")
                .font(.system(.headline, design: .serif))
                .foregroundStyle(Theme.ink)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Anemia")
    }
}

/// A soft, tinted notice: glyph, title over an optional message, an optional
/// trailing action. No border — the tint alone sets it apart.
struct NoticeRow<Accessory: View>: View {
    let symbol: String
    let title: String
    var message: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Theme.accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(Theme.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            accessory
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }
}

extension NoticeRow where Accessory == EmptyView {
    init(symbol: String, title: String, message: String? = nil) {
        self.init(symbol: symbol, title: title, message: message, accessory: { EmptyView() })
    }
}

/// The settings row grammar of the Mac app: a glyph tile that fills with clay
/// while the feature is doing its job, the title over a caption, the control
/// trailing.
struct GlyphRow<Accessory: View>: View {
    let symbol: String
    let title: String
    var caption: String?
    var active = false
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(active ? Color.white : Theme.inkSoft)
                .frame(width: 30, height: 30)
                .background(active ? AnyShapeStyle(Theme.accent.gradient) : AnyShapeStyle(Theme.idle),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .animation(Theme.spring, value: active)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .foregroundStyle(Theme.ink)
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(Theme.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 10)
            accessory
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

/// A grouped box of `GlyphRow`s with hairlines between them.
struct GlyphGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .anemiaCard()
    }
}

struct RowDivider: View {
    var body: some View {
        Divider()
            .overlay(Theme.stroke)
            .padding(.leading, 54)
    }
}

/// Latency: a verified request through the server reads strongest, a bare
/// ping recedes, and anything broken says so in clay.
struct PingBadge: View {
    var result: PingController.Result?
    var verdict: PingController.Verdict?

    var body: some View {
        switch (verdict, result) {
        case (.works(let ms), _):
            Text("\(ms) мс")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(Theme.ink)
        case (.broken(let reason), _):
            Text(reason)
                .font(.caption)
                .foregroundStyle(Theme.accent)
                .multilineTextAlignment(.trailing)
        case (nil, .measuring):
            ProgressView()
                .controlSize(.small)
        case (nil, .ms(let ms)):
            Text("\(ms) мс")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(Theme.inkSoft)
        case (nil, .failed):
            Text("нет ответа")
                .font(.caption)
                .foregroundStyle(Theme.accent)
        case (nil, nil):
            EmptyView()
        }
    }
}

/// Three bars of steadiness from the ping history.
struct StabilityBars: View {
    let score: Double

    private var level: Int {
        score <= 0.01 ? 0 : (score >= 0.75 ? 3 : (score >= 0.5 ? 2 : 1))
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(index < level ? Theme.ink : Theme.stroke)
                    .frame(width: 3, height: 5 + CGFloat(index) * 3)
            }
        }
        .accessibilityLabel("Стабильность \(Int((score * 100).rounded())) "
                            + WorldMap.plural(Int((score * 100).rounded()), "процент", "процента", "процентов"))
    }
}

/// The flag of a server's country, or a globe.
struct FlagBadge: View {
    let code: String?
    var size: CGFloat = 22

    var body: some View {
        Group {
            if let code {
                Text(Country.flag(code))
                    .font(.system(size: size))
            } else {
                Image(systemName: "globe.europe.africa.fill")
                    .font(.system(size: size * 0.85))
                    .foregroundStyle(Theme.accent)
            }
        }
        .accessibilityHidden(true)
    }
}

/// One server: flag, name over protocol and address, quality trailing.
struct ServerRow: View {
    let server: ProxyServer
    var isSelected = false
    var ping: PingController.Result?
    var verdict: PingController.Verdict?
    var stability: Double?
    /// Masking learned for this server, when it differs from the chosen one.
    var learnedMasking: MaskingProfile?
    var isFavorite = false

    var body: some View {
        HStack(spacing: 10) {
            FlagBadge(code: Country.code(inServerName: server.name), size: 20)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(place)
                    .foregroundStyle(server.runsOnIOS ? Theme.ink : Theme.inkSoft)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.inkSoft)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if isFavorite {
                Image(systemName: "star.fill")
                    .font(.caption2)
                    .foregroundStyle(Theme.accent)
                    .accessibilityLabel("В избранном")
            }
            if let learnedMasking {
                Image(systemName: "theatermasks.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
                    .accessibilityLabel("Маскировка «\(learnedMasking.russianTitle)» подобрана для этого сервера")
            }
            if let stability, verdict != nil || ping != nil {
                StabilityBars(score: stability)
            }
            PingBadge(result: ping, verdict: verdict)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
        }
        .contentShape(Rectangle())
    }

    private var place: String {
        let name = Country.place(inServerName: server.name)
        return name.isEmpty ? server.name : name
    }

    private var subtitle: String {
        guard server.runsOnIOS else { return server.kindLabel + " — не поддерживается" }
        return server.kindLabel + " · " + server.address
    }
}

/// Download and upload with their session totals, plus the speed curve —
/// the Mac app's traffic strip.
struct TrafficStrip: View {
    let speed: (download: Double, upload: Double)?
    let received: Int64
    let sent: Int64
    let history: [TrafficPoint]
    let isLive: Bool

    var body: some View {
        HStack(spacing: 16) {
            metric(symbol: "arrow.down.circle.fill", tint: Theme.accent,
                   label: "Загрузка", speed: speed?.download, total: received)
            metric(symbol: "arrow.up.circle.fill", tint: Theme.inkSoft,
                   label: "Отдача", speed: speed?.upload, total: sent)
            Sparkline(history: history)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
        }
        .opacity(isLive ? 1 : 0.45)
        .animation(Theme.spring, value: isLive)
    }

    private func metric(symbol: String, tint: Color, label: String,
                        speed: Double?, total: Int64) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 19))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 0) {
                Text(Speed.text(speed ?? 0))
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.ink)
                    .contentTransition(.numericText())
                Text(Bytes.text(total))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.inkSoft)
            }
            .lineLimit(1)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(Speed.text(speed ?? 0)), всего \(Bytes.text(total))")
    }
}

/// The session's traffic curve: download as a filled clay area, upload as a
/// thin ink line, scaled together.
struct Sparkline: View {
    let history: [TrafficPoint]

    var body: some View {
        Canvas { context, size in
            let width = size.width
            let height = size.height
            context.stroke(Path(CGRect(x: 0, y: height - 1, width: width, height: 1)),
                           with: .color(Theme.stroke))
            guard history.count >= 2, width > 2, height > 4 else { return }
            let peak = max(history.map { max($0.down, $0.up) }.max() ?? 0, 64_000)
            let step = width / CGFloat(TunnelController.historyCapacity - 1)
            let offset = max(TunnelController.historyCapacity - history.count, 0)
            func point(_ index: Int, _ value: Double) -> CGPoint {
                CGPoint(x: CGFloat(offset + index) * step,
                        y: height - 1.5 - (height - 4) * CGFloat(min(value / peak, 1)))
            }

            var area = Path()
            area.move(to: CGPoint(x: CGFloat(offset) * step, y: height - 1))
            for (index, sample) in history.enumerated() {
                area.addLine(to: point(index, sample.down))
            }
            area.addLine(to: CGPoint(x: point(history.count - 1, 0).x, y: height - 1))
            area.closeSubpath()
            context.fill(area, with: .linearGradient(
                Gradient(colors: [Theme.accent.opacity(0.32), Theme.accent.opacity(0.05)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: height)))

            var down = Path()
            for (index, sample) in history.enumerated() {
                let position = point(index, sample.down)
                index == 0 ? down.move(to: position) : down.addLine(to: position)
            }
            context.stroke(down, with: .color(Theme.accent.opacity(0.9)),
                           style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))

            var up = Path()
            for (index, sample) in history.enumerated() {
                let position = point(index, sample.up)
                index == 0 ? up.move(to: position) : up.addLine(to: position)
            }
            context.stroke(up, with: .color(Theme.inkSoft.opacity(0.6)),
                           style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))

            if let last = history.last {
                let bead = point(history.count - 1, last.down)
                context.fill(Path(ellipseIn: CGRect(x: bead.x - 2.5, y: bead.y - 2.5, width: 5, height: 5)),
                             with: .color(Theme.accent))
            }
        }
        .accessibilityHidden(true)
    }
}
