import LoaderCore
import SwiftUI

/// The world behind the connection state — the main screen's hero, as on the
/// Mac.
///
///  * Land is a honeycomb of dots on a 2° grid; the dots around a country
///    that holds servers warm up to clay, so a park reads as a region.
///  * An ink dot is you, the exit is the clay mark with its name beside it,
///    and a route joins them: dotted while idle, drawing itself while
///    connecting, solid with travelling packets once traffic flows.
///  * Tapping a country with servers picks its best one while nothing is
///    connected; the tap also names the country.
struct WorldMap: View {
    struct Park: Equatable {
        let code: String
        let count: Int
        let best: Int?
    }

    struct Snapshot: Equatable {
        var parks: [Park] = []
        var home: String?
        var exit: String?
        var exitLabel: String?
        var connected = false
        var connecting = false
    }

    let snapshot: Snapshot
    var canPick = false
    var onPick: ((String) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var chip: Chip?
    /// The pending clear of `chip`, so a second tap can cancel the first.
    @State private var chipTask: Task<Void, Never>?

    private struct Chip: Equatable {
        let code: String
        let title: String
        let detail: String?
    }

    var body: some View {
        GeometryReader { geometry in
            let rect = MapGeometry.fit(in: geometry.size)
            ZStack(alignment: .topLeading) {
                ZStack {
                    LandCanvas(parks: snapshot.parks.map(\.code))
                        .equatable()
                    markers
                }
                .mask(Self.fade)

                if let chip {
                    MapChip(title: chip.title, detail: chip.detail)
                        .position(chipCenter(for: chip.code, rect: rect, bounds: geometry.size))
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture().onEnded { tap in
                    handleTap(at: tap.location, rect: rect)
                }
            )
            .animation(Theme.springQuick, value: chip)
        }
        // Top right: the status headline owns the bottom of the map.
        .overlay(alignment: .topTrailing) { legend }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary)
    }

    @ViewBuilder private var markers: some View {
        if (snapshot.connected || snapshot.connecting) && !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                MarkerCanvas(snapshot: snapshot, highlight: chip?.code,
                             time: timeline.date.timeIntervalSinceReferenceDate)
            }
        } else {
            MarkerCanvas(snapshot: snapshot, highlight: chip?.code, time: nil)
        }
    }

    /// The reach of the server list, where the map fades out.
    @ViewBuilder private var legend: some View {
        if !snapshot.parks.isEmpty {
            let servers = snapshot.parks.reduce(0) { $0 + $1.count }
            HStack(spacing: 5) {
                Circle()
                    .strokeBorder(Theme.accent.opacity(0.7), lineWidth: 1.1)
                    .frame(width: 8, height: 8)
                Text("\(snapshot.parks.count) \(Self.countries(snapshot.parks.count)) · \(servers) \(Self.servers(servers))")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.inkSoft)
            .padding(.trailing, 16)
            .padding(.top, 6)
            .allowsHitTesting(false)
        }
    }

    // MARK: - Interaction

    private func handleTap(at point: CGPoint, rect: CGRect) {
        guard let code = Self.nearestCountry(to: point, rect: rect, snapshot: snapshot) else {
            chip = nil
            return
        }
        let park = snapshot.parks.first { $0.code == code }
        var facts: [String] = []
        if code == snapshot.home { facts.append("вы здесь") }
        if code == snapshot.exit { facts.append("выход") }
        if let park {
            facts.append("\(park.count) \(Self.servers(park.count))")
            if let best = park.best { facts.append("лучший \(best) мс") }
        }
        chip = Chip(code: code, title: "\(Country.flag(code)) \(Country.name(code))",
                    detail: facts.isEmpty ? nil : facts.joined(separator: " · "))
        if canPick, park != nil, code != snapshot.exit {
            onPick?(code)
        }
        // @State only accepts writes from the main actor, and a bare Task
        // inherits none of this view's isolation. The task is kept and
        // cancelled: without that, tapping the same country twice in 2.5 s
        // let the first tap's timer fire and clear the chip the second tap
        // had just raised.
        chipTask?.cancel()
        chipTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled, chip?.code == code { chip = nil }
        }
    }

    /// The placeable country whose mark lies closest to `point`, within a
    /// 22 pt grab radius — a fingertip, not a cursor.
    private static func nearestCountry(to point: CGPoint, rect: CGRect, snapshot: Snapshot) -> String? {
        var candidates = snapshot.parks.map(\.code)
        if let home = snapshot.home { candidates.append(home) }
        if let exit = snapshot.exit { candidates.append(exit) }
        var best: (code: String, distance: CGFloat)?
        for code in candidates {
            guard let center = CountryGeo.centers[code] else { continue }
            let position = MapGeometry.project(lat: center.lat, lon: center.lon, in: rect)
            let distance = hypot(position.x - point.x, position.y - point.y)
            if distance < 22, distance < (best?.distance ?? .greatestFiniteMagnitude) {
                best = (code, distance)
            }
        }
        return best?.code
    }

    private func chipCenter(for code: String, rect: CGRect, bounds: CGSize) -> CGPoint {
        guard let center = CountryGeo.centers[code] else { return .zero }
        let position = MapGeometry.project(lat: center.lat, lon: center.lon, in: rect)
        return CGPoint(x: min(max(position.x, 80), bounds.width - 80),
                       y: max(position.y - 26, 16))
    }

    private var summary: String {
        var parts: [String] = []
        if let home = snapshot.home { parts.append("Вы в \(Country.name(home))") }
        if let exit = snapshot.exit {
            parts.append((snapshot.connected ? "Выход через " : "Выбран выход ") + Country.name(exit))
        }
        if !snapshot.parks.isEmpty {
            let n = snapshot.parks.count
            parts.append("Серверы в \(n) \(Self.plural(n, "стране", "странах", "странах"))")
        }
        return parts.isEmpty ? "Карта мира" : parts.joined(separator: ". ")
    }

    private static func servers(_ count: Int) -> String {
        plural(count, "сервер", "сервера", "серверов")
    }

    private static func countries(_ count: Int) -> String {
        plural(count, "страна", "страны", "стран")
    }

    static func plural(_ count: Int, _ one: String, _ few: String, _ many: String) -> String {
        let tens = count % 100
        if (11...14).contains(tens) { return many }
        switch count % 10 {
        case 1: return one
        case 2, 3, 4: return few
        default: return many
        }
    }

    /// Full strength across the upper map, dissolving toward the bottom
    /// (where the status text sits) and at the sides, so the map melts into
    /// the screen instead of ending in a box.
    static var fade: some View {
        LinearGradient(stops: [.init(color: .black, location: 0),
                               .init(color: .black, location: 0.5),
                               .init(color: .black.opacity(0.18), location: 0.82),
                               .init(color: .clear, location: 0.98)],
                       startPoint: .top, endPoint: .bottom)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0),
                                         .init(color: .black, location: 0.07),
                                         .init(color: .black, location: 0.93),
                                         .init(color: .clear, location: 1)],
                                 startPoint: .leading, endPoint: .trailing))
    }
}

// MARK: - Land

/// The land dots, redrawn only when the size, the theme or the set of server
/// countries changes.
private struct LandCanvas: View, Equatable {
    let parks: [String]

    var body: some View {
        Canvas { context, size in
            let rect = MapGeometry.fit(in: size)
            guard rect.width > 1 else { return }
            let step = rect.width / 180
            let radius = step * 0.37
            let warmRadius = 7.0
            let centers = parks.compactMap { CountryGeo.centers[$0] }
            var buckets = [Path](repeating: Path(), count: 4)
            for cell in WorldDots.cells {
                let point = CGPoint(x: rect.minX + CGFloat(cell.x) * rect.width,
                                    y: rect.minY + CGFloat(cell.y) * rect.height)
                var warmth = 0.0
                for center in centers {
                    let dLat = cell.lat - center.lat
                    let dLon = (cell.lon - center.lon) * cos(cell.lat * .pi / 180)
                    warmth = max(warmth, 1 - (dLat * dLat + dLon * dLon).squareRoot() / warmRadius)
                }
                let bucket = warmth <= 0 ? 0 : min(3, 1 + Int(warmth * 3))
                buckets[bucket].addEllipse(in: CGRect(x: point.x - radius, y: point.y - radius,
                                                      width: 2 * radius, height: 2 * radius))
            }
            context.fill(buckets[0], with: .color(Theme.mapLand))
            context.fill(buckets[1], with: .color(Theme.accent.opacity(0.30)))
            context.fill(buckets[2], with: .color(Theme.accent.opacity(0.45)))
            context.fill(buckets[3], with: .color(Theme.accent.opacity(0.60)))
        }
        .drawingGroup()
    }
}

// MARK: - Marks

private struct MarkerCanvas: View {
    let snapshot: WorldMap.Snapshot
    let highlight: String?
    /// Seconds since the reference date, or nil for a still frame.
    let time: Double?

    var body: some View {
        Canvas { context, size in
            let rect = MapGeometry.fit(in: size)
            guard rect.width > 1 else { return }

            func at(_ code: String?) -> CGPoint? {
                guard let code, let center = CountryGeo.centers[code] else { return nil }
                return MapGeometry.project(lat: center.lat, lon: center.lon, in: rect)
            }
            func dot(_ point: CGPoint, _ radius: CGFloat, _ color: Color) {
                context.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius,
                                                    width: radius * 2, height: radius * 2)),
                             with: .color(color))
            }
            func ring(_ point: CGPoint, _ radius: CGFloat, _ color: Color,
                      width: CGFloat = 1, dash: [CGFloat] = []) {
                context.stroke(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius,
                                                      width: radius * 2, height: radius * 2)),
                               with: .color(color), style: StrokeStyle(lineWidth: width, dash: dash))
            }
            /// 0…1 sawtooth with the given period.
            func cycle(_ period: Double, offset: Double = 0) -> CGFloat? {
                guard let time else { return nil }
                let value = (time / period + offset).truncatingRemainder(dividingBy: 1)
                return CGFloat(value < 0 ? value + 1 : value)
            }

            let home = at(snapshot.home)
            let exit = at(snapshot.exit)

            // Server countries. In a dense region the rings overlapped into a
            // blob, so a crowded country gets a plain dot — the warmed land
            // around it already says "servers here".
            let parks = snapshot.parks.compactMap { park in
                at(park.code).map { (code: park.code, count: park.count, point: $0) }
            }
            for park in parks where park.code != snapshot.exit {
                let crowded = parks.contains { other in
                    other.code != park.code && hypot(other.point.x - park.point.x, other.point.y - park.point.y) < 13
                }
                if crowded {
                    dot(park.point, 2.1, Theme.accent.opacity(0.9))
                } else {
                    // log2(0) is -inf, and an infinite size reaches the canvas
                    // as a rect with an infinite origin.
                    let size = 2.4 + min(1.6, CGFloat(log2(Double(max(park.count, 1)))))
                    ring(park.point, size + 1.4, Theme.accent.opacity(0.55), width: 1.1)
                    dot(park.point, size * 0.5, Theme.accent)
                }
            }

            // The route, you → exit.
            if let home, let exit, snapshot.home != snapshot.exit {
                let arc = RouteArc(from: home, to: exit)
                if snapshot.connected {
                    context.stroke(arc.path, with: .color(Theme.accent.opacity(0.16)),
                                   style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    context.stroke(arc.path,
                                   with: .linearGradient(Gradient(colors: [Theme.accent.opacity(0.35), Theme.accent]),
                                                         startPoint: home, endPoint: exit),
                                   style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                    for step in 0..<2 {
                        guard let raw = cycle(2.6, offset: Double(step) * 0.5) else { break }
                        let t = raw * raw * (3 - 2 * raw)
                        dot(arc.point(t), 2.2, Theme.accent.opacity(Double(sin(t * .pi))))
                    }
                } else if snapshot.connecting {
                    let progress = cycle(1.6) ?? 1
                    context.stroke(arc.path.trimmedPath(from: 0, to: progress),
                                   with: .color(Theme.accent.opacity(0.75)),
                                   style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 3]))
                } else {
                    context.stroke(arc.path, with: .color(Theme.inkSoft.opacity(0.5)),
                                   style: StrokeStyle(lineWidth: 1.1, lineCap: .round, dash: [0.5, 3.5]))
                }
            }

            // You.
            if let home {
                dot(home, 6, Theme.ink.opacity(0.10))
                dot(home, 3.2, Theme.ink)
                ring(home, 3.2, Theme.ground, width: 1.2)
            }

            // The exit.
            if let exit {
                if snapshot.connected {
                    let breathe = cycle(2.4).map { 0.5 + 0.5 * sin($0 * 2 * .pi) } ?? 0.5
                    dot(exit, 7 + 3 * breathe, Theme.accent.opacity(0.22 - 0.1 * Double(breathe)))
                    dot(exit, 4.2, Theme.accent)
                    ring(exit, 4.2, Theme.ground, width: 1.4)
                } else if snapshot.connecting {
                    if let q = cycle(1.4) {
                        ring(exit, 4 + 10 * q, Theme.accent.opacity(0.6 * Double(1 - q)), width: 1.4)
                    }
                    dot(exit, 3.8, Theme.accent)
                } else {
                    ring(exit, 7, Theme.accent.opacity(0.55), width: 1, dash: [2, 2])
                    dot(exit, 3.6, Theme.accent.opacity(0.9))
                }
            }

            // Labels: the exit's name beside it, on the side away from you.
            let exitToRight: Bool = {
                guard let home, let exit else { return true }
                return exit.x >= home.x
            }()
            if let exit, let text = snapshot.exitLabel {
                let resolved = context.resolve(Text(text)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(snapshot.connected ? Theme.accent : Theme.ink))
                let measured = resolved.measure(in: CGSize(width: 240, height: 40))
                let box = LabelPlacement.pill(size: measured, beside: exit, toRight: exitToRight,
                                              gap: 10, bounds: size)
                let pill = Path(roundedRect: box, cornerRadius: box.height / 2, style: .continuous)
                context.fill(pill, with: .color(Theme.ground.opacity(0.92)))
                context.stroke(pill, with: .color(snapshot.connected ? Theme.accent.opacity(0.45) : Theme.stroke),
                               lineWidth: 1)
                context.draw(resolved, at: CGPoint(x: box.midX, y: box.midY), anchor: .center)
            }
            if let home, snapshot.home != snapshot.exit {
                let resolved = context.resolve(Text("Вы")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.inkSoft))
                let measured = resolved.measure(in: CGSize(width: 60, height: 20))
                let box = LabelPlacement.pill(size: measured, beside: home, toRight: !exitToRight,
                                              gap: 8, bounds: size, padding: 0)
                context.draw(resolved, at: CGPoint(x: box.midX, y: box.midY), anchor: .center)
            }

            // The tapped country.
            if let point = at(highlight) {
                ring(point, 11, Theme.ink.opacity(0.45), width: 1, dash: [2, 2])
            }
        }
    }
}

/// A flight-map arc: the control point lifts toward the pole in proportion to
/// the span, so short hops stay flat and long ones sweep.
private struct RouteArc {
    let a: CGPoint
    let b: CGPoint
    let c: CGPoint

    init(from a: CGPoint, to b: CGPoint) {
        self.a = a
        self.b = b
        let span = hypot(b.x - a.x, b.y - a.y)
        c = CGPoint(x: (a.x + b.x) / 2, y: min(a.y, b.y) - span * 0.3)
    }

    var path: Path {
        var path = Path()
        path.move(to: a)
        path.addQuadCurve(to: b, control: c)
        return path
    }

    func point(_ t: CGFloat) -> CGPoint {
        let u = 1 - t
        return CGPoint(x: u * u * a.x + 2 * u * t * c.x + t * t * b.x,
                       y: u * u * a.y + 2 * u * t * c.y + t * t * b.y)
    }
}

private enum LabelPlacement {
    /// A label box vertically centered on `point`, beside it on the chosen
    /// side — flipped when that side would leave the map.
    static func pill(size: CGSize, beside point: CGPoint, toRight: Bool, gap: CGFloat,
                     bounds: CGSize, padding: CGFloat = 7) -> CGRect {
        let width = size.width + padding * 2
        let height = size.height + (padding > 0 ? 6 : 0)
        var right = toRight
        if right, point.x + gap + width > bounds.width - 4 { right = false }
        if !right, point.x - gap - width < 4 { right = true }
        let x = right ? point.x + gap : point.x - gap - width
        let y = min(max(point.y - height / 2, 2), bounds.height - height - 2)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

/// The floating label that names a tapped country.
private struct MapChip: View {
    let title: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.ink)
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.inkSoft)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.stroke))
        .fixedSize()
    }
}
