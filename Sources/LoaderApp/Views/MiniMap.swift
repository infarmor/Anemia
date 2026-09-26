import SwiftUI
import LoaderCore

/// The world behind the connection state — the main window's hero.
///
///  * Land is a honeycomb of dots on a 2° grid, sampled once from coastline
///    rings (seas and lakes carved out even-odd) and drawn as one static
///    layer; only the live marks above it repaint while animating.
///  * Every mark says one thing: an ink dot is you, clay rings are the
///    countries your servers are in (the land around them warms up), and the
///    exit is the clay mark with its name beside it. A route joins you to the
///    exit — dotted while idle, drawing itself while connecting, solid with
///    travelling packets once traffic flows.
///  * Hover names a country and what it holds; clicking a server country
///    while disconnected picks its best server.
///
/// Geography is best-effort and honest about it: a server's country comes
/// from the flag emoji in its name, the home country from the physical
/// interface's geolocation. Anything unplaceable is simply not drawn.
struct MiniMap: View {
    @EnvironmentObject var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The country under the cursor. Stored as a code, not a point, so the
    /// map re-renders when the answer changes, not on every mouse move.
    @State private var hoverCountry: String?

    fileprivate struct Park: Equatable {
        let cc: String
        let count: Int
        let bestPing: Int?
    }

    /// Everything the canvases need, computed once per body evaluation —
    /// never per animation frame.
    fileprivate struct Snapshot: Equatable {
        var parks: [Park] = []
        var home: String?
        var exit: String?
        var exitLabel: String?
        var connected = false
        var connecting = false
    }

    private var snapshot: Snapshot {
        var counts: [String: Int] = [:]
        var best: [String: Int] = [:]
        for server in state.allServers {
            guard let cc = state.serverCountry(server.name)?.uppercased(),
                  CountryGeo.centers[cc] != nil else { continue }
            counts[cc, default: 0] += 1
            if let ms = state.pings[server.id]?.value {
                best[cc] = min(best[cc] ?? .max, ms)
            }
        }
        var snap = Snapshot()
        snap.parks = counts.keys.sorted().map { Park(cc: $0, count: counts[$0]!, bestPing: best[$0]) }
        snap.home = state.homeCountry?.uppercased()
        // The exit is the server the session dials — the list can move the
        // selection while connected without reconnecting.
        let live = state.isConnected || state.connection == .connecting
        if let server = (live ? state.sessionServer : nil) ?? state.selectedServer,
           let cc = state.serverCountry(server.name)?.uppercased(), CountryGeo.centers[cc] != nil {
            snap.exit = cc
            var label = "\(Self.flag(cc)) \(Self.placeName(server.name, country: cc))"
            if state.isConnected, let ms = state.proxyLatency { label += " · \(Format.ping(ms))" }
            snap.exitLabel = label
        }
        snap.connected = state.isConnected
        snap.connecting = state.connection == .connecting
        return snap
    }

    var body: some View {
        let snap = snapshot
        GeometryReader { geo in
            let rect = MapGeometry.fit(in: geo.size)
            ZStack(alignment: .topLeading) {
                ZStack {
                    LandCanvas(parks: snap.parks.map(\.cc))
                        .equatable()
                    markers(snap)
                }
                .mask(Self.heroFade)

                if let cc = hoverCountry, let text = hoverText(cc, snap) {
                    MapChip(title: text.title, detail: text.detail)
                        .position(chipCenter(for: cc, rect: rect, bounds: geo.size))
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let point):
                    let hit = Self.nearestCountry(to: point, rect: rect, snap: snap)
                    if hit != hoverCountry { hoverCountry = hit }
                    let pickable = hit.map { cc in snap.parks.contains { $0.cc == cc } } ?? false
                    (pickable && canPick ? NSCursor.pointingHand : NSCursor.arrow).set()
                case .ended:
                    hoverCountry = nil
                    NSCursor.arrow.set()
                }
            }
            .gesture(SpatialTapGesture().onEnded { tap in
                guard canPick, let cc = Self.nearestCountry(to: tap.location, rect: rect, snap: snap),
                      snap.parks.contains(where: { $0.cc == cc }),
                      let id = bestServer(in: cc) else { return }
                state.select(id)
            })
            .animation(Theme.springQuick, value: hoverCountry)
        }
        .overlay(alignment: .bottomTrailing) { legend(snap) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary(snap))
    }

    // MARK: - Layers

    @ViewBuilder private func markers(_ snap: Snapshot) -> some View {
        if (snap.connected || snap.connecting) && !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                MarkerCanvas(snap: snap, hover: hoverCountry, time: timeline.date.timeIntervalSinceReferenceDate)
            }
        } else {
            MarkerCanvas(snap: snap, hover: hoverCountry, time: nil)
        }
    }

    /// The reach of the server list, beside the status line where the map
    /// fades out (the marks name themselves: "You", the exit's pill).
    private func legend(_ snap: Snapshot) -> some View {
        Group {
            if !snap.parks.isEmpty {
                let servers = state.allServers.count
                LegendItem(kind: .park,
                           title: "\(snap.parks.count) \(snap.parks.count == 1 ? "country" : "countries") · \(servers) server\(servers == 1 ? "" : "s")")
            }
        }
        .padding(.bottom, 18)
        .padding(.trailing, 20)
        .allowsHitTesting(false)
    }

    // MARK: - Interaction

    /// A click picks a server only while nothing is live: changing the exit
    /// under a running session belongs to the switch and the server list.
    private var canPick: Bool {
        !state.isConnected && state.connection != .connecting
    }

    /// The country's best server: kxc's rank first, then the latest ping.
    private func bestServer(in cc: String) -> UUID? {
        state.allServers
            .filter { state.serverCountry($0.name)?.uppercased() == cc }
            .min { a, b in
                let ra = state.rankPosition[a.id] ?? .max, rb = state.rankPosition[b.id] ?? .max
                if ra != rb { return ra < rb }
                return (state.pings[a.id]?.value ?? .max) < (state.pings[b.id]?.value ?? .max)
            }?.id
    }

    /// The placeable country whose mark lies closest to `point`, within a
    /// 12 pt grab radius: server countries, home and the exit.
    fileprivate static func nearestCountry(to point: CGPoint, rect: CGRect, snap: Snapshot) -> String? {
        var candidates = snap.parks.map(\.cc)
        if let home = snap.home { candidates.append(home) }
        if let exit = snap.exit { candidates.append(exit) }
        var best: (cc: String, d: CGFloat)?
        for cc in candidates {
            guard let c = CountryGeo.centers[cc] else { continue }
            let p = MapGeometry.project(lat: c.lat, lon: c.lon, in: rect)
            let d = hypot(p.x - point.x, p.y - point.y)
            if d < 12, d < (best?.d ?? .greatestFiniteMagnitude) { best = (cc, d) }
        }
        return best?.cc
    }

    private func hoverText(_ cc: String, _ snap: Snapshot) -> (title: String, detail: String?)? {
        guard CountryGeo.centers[cc] != nil else { return nil }
        let title = "\(Self.flag(cc)) \(Self.countryName(cc))"
        var facts: [String] = []
        if cc == snap.home { facts.append("you") }
        if cc == snap.exit { facts.append("exit") }
        if let park = snap.parks.first(where: { $0.cc == cc }) {
            facts.append("\(park.count) \(park.count == 1 ? "server" : "servers")")
            if let ms = park.bestPing { facts.append("best \(Format.ping(ms))") }
            if canPick, cc != snap.exit { facts.append("click to use") }
        }
        return (title, facts.isEmpty ? nil : facts.joined(separator: " · "))
    }

    /// Just above the mark, kept inside the map's bounds.
    private func chipCenter(for cc: String, rect: CGRect, bounds: CGSize) -> CGPoint {
        guard let c = CountryGeo.centers[cc] else { return .zero }
        let p = MapGeometry.project(lat: c.lat, lon: c.lon, in: rect)
        return CGPoint(x: min(max(p.x, 90), bounds.width - 90),
                       y: max(p.y - 26, 18))
    }

    private func accessibilitySummary(_ snap: Snapshot) -> String {
        var parts: [String] = []
        if let home = snap.home { parts.append("You are in \(Self.countryName(home))") }
        if let exit = snap.exit {
            parts.append((snap.connected ? "Exiting through " : "Selected exit ") + Self.countryName(exit))
        }
        if !snap.parks.isEmpty { parts.append("Servers in \(snap.parks.count) countries") }
        return parts.isEmpty ? "World map" : parts.joined(separator: ". ")
    }

    // MARK: - Naming

    /// Regional-indicator flag for an ISO code.
    static func flag(_ cc: String) -> String {
        guard cc.count == 2 else { return "" }
        return String(cc.unicodeScalars.compactMap { scalar in
            (65...90).contains(scalar.value)
                ? UnicodeScalar(0x1F1E6 - 65 + scalar.value).map(Character.init)
                : nil
        })
    }

    static func countryName(_ cc: String) -> String {
        Locale.current.localizedString(forRegionCode: cc) ?? cc
    }

    /// The server's own place name ("🇳🇱 Amsterdam #2" → "Amsterdam #2"), or
    /// the country when the name is nothing but a flag.
    static func placeName(_ serverName: String, country cc: String) -> String {
        let scalars = serverName.unicodeScalars.filter { !(0x1F1E6...0x1F1FF).contains($0.value) }
        let trimmed = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !trimmed.isEmpty else { return countryName(cc) }
        return trimmed.count > 22 ? String(trimmed.prefix(21)) + "…" : trimmed
    }

    /// Full strength across the upper map, dissolving toward the bottom (where
    /// the status text sits) and at the side edges, so the map melts into the
    /// window instead of ending in a box.
    static var heroFade: some View {
        LinearGradient(stops: [.init(color: .black, location: 0),
                               .init(color: .black, location: 0.5),
                               .init(color: .black.opacity(0.18), location: 0.8),
                               .init(color: .clear, location: 0.97)],
                       startPoint: .top, endPoint: .bottom)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0),
                                         .init(color: .black, location: 0.08),
                                         .init(color: .black, location: 0.92),
                                         .init(color: .clear, location: 1)],
                                 startPoint: .leading, endPoint: .trailing))
    }
}

// MARK: - Geometry

/// Equirectangular, cropped to the inhabited band (80°N … 56°S): the polar
/// caps hold no servers and would only push the continents into a strip.
fileprivate enum MapGeometry {
    static let latTop = 80.0
    static let latBottom = -56.0
    static var aspect: CGFloat { CGFloat(360 / (latTop - latBottom)) }

    /// The aspect-fit map rectangle, centered in `size`.
    static func fit(in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let width = min(size.width, size.height * aspect)
        let height = width / aspect
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2,
                      width: width, height: height)
    }

    static func project(lat: Double, lon: Double, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + CGFloat((lon + 180) / 360) * rect.width,
                y: rect.minY + CGFloat((latTop - lat) / (latTop - latBottom)) * rect.height)
    }
}

// MARK: - Static layer (land)

/// The land dots, drawn only when the size, the theme or the set of server
/// countries changes. Dots near a server country take on the clay, so the
/// park reads as a region rather than a pin.
private struct LandCanvas: View, Equatable {
    let parks: [String]

    var body: some View {
        Canvas { ctx, size in
            let rect = MapGeometry.fit(in: size)
            guard rect.width > 1 else { return }
            let step = rect.width / 180                  // one 2° cell
            let r = step * 0.37
            let warmRadius = 7.0                         // degrees of warmth around a park
            let centers = parks.compactMap { CountryGeo.centers[$0] }
            // Bucketed by warmth: five batched fills instead of thousands.
            var buckets = [Path](repeating: Path(), count: 4)
            for cell in WorldDots.cells {
                let p = CGPoint(x: rect.minX + CGFloat(cell.x) * rect.width,
                                y: rect.minY + CGFloat(cell.y) * rect.height)
                var warmth = 0.0
                for c in centers {
                    let dLat = cell.lat - c.lat
                    let dLon = (cell.lon - c.lon) * cos(cell.lat * .pi / 180)
                    let d = (dLat * dLat + dLon * dLon).squareRoot()
                    warmth = max(warmth, 1 - d / warmRadius)
                }
                let bucket = warmth <= 0 ? 0 : min(3, 1 + Int(warmth * 3))
                buckets[bucket].addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
            }
            ctx.fill(buckets[0], with: .color(Theme.mapLand))
            ctx.fill(buckets[1], with: .color(Theme.accent.opacity(0.30)))
            ctx.fill(buckets[2], with: .color(Theme.accent.opacity(0.45)))
            ctx.fill(buckets[3], with: .color(Theme.accent.opacity(0.60)))
        }
        .drawingGroup()
    }
}

// MARK: - Live layer (marks + route)

private struct MarkerCanvas: View {
    let snap: MiniMap.Snapshot
    let hover: String?
    /// Seconds since the reference date, or nil for a still frame (idle, or
    /// Reduce Motion).
    let time: Double?

    var body: some View {
        Canvas { ctx, size in
            let rect = MapGeometry.fit(in: size)
            guard rect.width > 1 else { return }

            func at(_ cc: String?) -> CGPoint? {
                guard let cc, let c = CountryGeo.centers[cc] else { return nil }
                return MapGeometry.project(lat: c.lat, lon: c.lon, in: rect)
            }
            func dot(_ p: CGPoint, _ radius: CGFloat, _ color: Color) {
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius,
                                                width: radius * 2, height: radius * 2)),
                         with: .color(color))
            }
            func ring(_ p: CGPoint, _ radius: CGFloat, _ color: Color, width: CGFloat = 1, dash: [CGFloat] = []) {
                ctx.stroke(Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius,
                                                  width: radius * 2, height: radius * 2)),
                           with: .color(color), style: StrokeStyle(lineWidth: width, dash: dash))
            }
            /// 0…1 sawtooth with the given period.
            func cycle(_ period: Double, offset: Double = 0) -> CGFloat? {
                guard let time else { return nil }
                let v = (time / period + offset).truncatingRemainder(dividingBy: 1)
                return CGFloat(v < 0 ? v + 1 : v)
            }

            let home = at(snap.home)
            let exit = at(snap.exit)

            // 1. Server countries (the exit draws its own, stronger mark). In a
            // dense region like Europe the rings overlapped into a blob — a
            // crowded country gets a plain dot; the warmed land around it
            // already says "servers here".
            let parkPoints = snap.parks.compactMap { park in at(park.cc).map { (cc: park.cc, count: park.count, p: $0) } }
            for park in parkPoints where park.cc != snap.exit {
                let crowded = parkPoints.contains { other in
                    other.cc != park.cc && hypot(other.p.x - park.p.x, other.p.y - park.p.y) < 13
                }
                if crowded {
                    dot(park.p, 2.1, Theme.accent.opacity(0.9))
                } else {
                    let size = 2.4 + min(1.6, CGFloat(log2(Double(park.count))))
                    ring(park.p, size + 1.4, Theme.accent.opacity(0.55), width: 1.1)
                    dot(park.p, size * 0.5, Theme.accent)
                }
            }

            // 2. The route, you → exit.
            if let home, let exit, snap.home != snap.exit {
                let arc = RouteArc(from: home, to: exit)
                if snap.connected {
                    ctx.stroke(arc.path, with: .color(Theme.accent.opacity(0.16)),
                               style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    ctx.stroke(arc.path,
                               with: .linearGradient(Gradient(colors: [Theme.accent.opacity(0.35), Theme.accent]),
                                                     startPoint: home, endPoint: exit),
                               style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                    for k in 0..<2 {
                        guard let raw = cycle(2.6, offset: Double(k) * 0.5) else { break }
                        let t = raw * raw * (3 - 2 * raw)
                        dot(arc.point(t), 2.2, Theme.accent.opacity(Double(sin(t * .pi))))
                    }
                } else if snap.connecting {
                    let progress = cycle(1.6) ?? 1
                    ctx.stroke(arc.path.trimmedPath(from: 0, to: progress),
                               with: .color(Theme.accent.opacity(0.75)),
                               style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 3]))
                } else {
                    ctx.stroke(arc.path, with: .color(Theme.textLo.opacity(0.5)),
                               style: StrokeStyle(lineWidth: 1.1, lineCap: .round, dash: [0.5, 3.5]))
                }
            }

            // 3. You.
            if let home {
                dot(home, 6, Theme.textHi.opacity(0.10))
                dot(home, 3.2, Theme.textHi)
                ring(home, 3.2, Theme.ground, width: 1.2)
            }

            // 4. The exit.
            if let exit {
                if snap.connected {
                    let breathe = cycle(2.4).map { 0.5 + 0.5 * sin($0 * 2 * .pi) } ?? 0.5
                    dot(exit, 7 + 3 * breathe, Theme.accent.opacity(0.22 - 0.1 * Double(breathe)))
                    dot(exit, 4.2, Theme.accent)
                    ring(exit, 4.2, Theme.ground, width: 1.4)
                } else if snap.connecting {
                    if let q = cycle(1.4) {
                        ring(exit, 4 + 10 * q, Theme.accent.opacity(0.6 * Double(1 - q)), width: 1.4)
                    }
                    dot(exit, 3.8, Theme.accent)
                } else {
                    ring(exit, 7, Theme.accent.opacity(0.55), width: 1, dash: [2, 2])
                    dot(exit, 3.6, Theme.accent.opacity(0.9))
                }
            }

            // 5. Labels — the exit's name beside it, on the side away from
            // you; "You" on the other side.
            let exitToRight: Bool = {
                guard let home, let exit else { return true }
                return exit.x >= home.x
            }()
            if let exit, let text = snap.exitLabel {
                let resolved = ctx.resolve(Text(text)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(snap.connected ? Theme.accent : Theme.textHi))
                let measured = resolved.measure(in: CGSize(width: 260, height: 40))
                let box = LabelPlacement.pill(size: measured, beside: exit, toRight: exitToRight,
                                              gap: 10, bounds: size)
                let pill = Path(roundedRect: box, cornerRadius: box.height / 2, style: .continuous)
                ctx.fill(pill, with: .color(Theme.ground.opacity(0.92)))
                ctx.stroke(pill, with: .color(snap.connected ? Theme.accent.opacity(0.45) : Theme.stroke),
                           lineWidth: 1)
                ctx.draw(resolved, at: CGPoint(x: box.midX, y: box.midY), anchor: .center)
            }
            if let home, snap.home != snap.exit {
                let resolved = ctx.resolve(Text("You")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textLo))
                let measured = resolved.measure(in: CGSize(width: 60, height: 20))
                let box = LabelPlacement.pill(size: measured, beside: home, toRight: !exitToRight,
                                              gap: 8, bounds: size, padding: 0)
                ctx.draw(resolved, at: CGPoint(x: box.midX, y: box.midY), anchor: .center)
            }

            // 6. Hover halo.
            if let p = at(hover) {
                ring(p, 9, Theme.textHi.opacity(0.45), width: 1, dash: [2, 2])
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
        var p = Path()
        p.move(to: a)
        p.addQuadCurve(to: b, control: c)
        return p
    }

    func point(_ t: CGFloat) -> CGPoint {
        let u = 1 - t
        let wa = u * u, wc = 2 * u * t, wb = t * t
        return CGPoint(x: wa * a.x + wc * c.x + wb * b.x,
                       y: wa * a.y + wc * c.y + wb * b.y)
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

// MARK: - Chrome

/// The floating label that names a hovered country.
private struct MapChip: View {
    let title: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textHi)
            if let detail {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textLo)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.stroke))
        .fixedSize()
    }
}

private struct LegendItem: View {
    enum Kind { case home, exit, park }
    let kind: Kind
    let title: String

    var body: some View {
        HStack(spacing: 5) {
            ZStack {
                switch kind {
                case .home:
                    Circle().fill(Theme.textHi).frame(width: 6, height: 6)
                case .exit:
                    Circle().fill(Theme.accent).frame(width: 7, height: 7)
                case .park:
                    Circle().strokeBorder(Theme.accent.opacity(0.7), lineWidth: 1.1).frame(width: 8, height: 8)
                }
            }
            .frame(width: 9, height: 9)
            Text(title)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(Theme.textLo)
    }
}

// MARK: - Land

/// Land cell centres on a 2° grid, odd rows offset by half a cell (a
/// honeycomb, not a laser grid), sampled once from the coastline rings.
private enum WorldDots {
    struct Cell {
        let lat: Double
        let lon: Double
        /// Normalised position inside the map rectangle (0…1).
        let x: Double
        let y: Double
    }

    static let cells: [Cell] = {
        var out: [Cell] = []
        let rows = Int((MapGeometry.latTop - MapGeometry.latBottom) / 2)
        for row in 0..<rows {
            let lat = MapGeometry.latTop - 1 - Double(row) * 2
            let shift = row % 2 == 0 ? 0.0 : 1.0
            for col in 0..<180 {
                let lon = -179 + Double(col) * 2 + shift
                guard lon < 180 else { continue }
                var inside = false
                for ring in Coastline.rings where ring.contains(lat: lat, lon: lon) {
                    inside.toggle()   // even-odd across rings: seas inside land are holes
                }
                guard inside else { continue }
                out.append(Cell(lat: lat, lon: lon,
                                x: (lon + 180) / 360,
                                y: (MapGeometry.latTop - lat) / (MapGeometry.latTop - MapGeometry.latBottom)))
            }
        }
        return out
    }()
}

/// One closed coastline ring with a bounding box and an even-odd
/// point-in-polygon test.
private struct Ring {
    private let lons: [Double]
    private let lats: [Double]
    private let minLat, maxLat, minLon, maxLon: Double

    /// Authored as [lon, lat, lon, lat, …] — longitude first, the natural
    /// order when tracing a coastline on a map.
    init(_ flat: [Double]) {
        var lo: [Double] = [], la: [Double] = []
        var i = 0
        while i + 1 < flat.count {
            lo.append(flat[i]); la.append(flat[i + 1]); i += 2
        }
        lons = lo; lats = la
        minLat = la.min() ?? 0; maxLat = la.max() ?? 0
        minLon = lo.min() ?? 0; maxLon = lo.max() ?? 0
    }

    func contains(lat: Double, lon: Double) -> Bool {
        guard lat >= minLat, lat <= maxLat, lon >= minLon, lon <= maxLon else { return false }
        var inside = false
        var j = lats.count - 1
        for i in 0..<lats.count {
            if (lats[i] > lat) != (lats[j] > lat) {
                let crossLon = (lons[j] - lons[i]) * (lat - lats[i]) / (lats[j] - lats[i]) + lons[i]
                if lon < crossLon { inside.toggle() }
            }
            j = i
        }
        return inside
    }
}

/// Hand-traced coastlines at roughly country-outline fidelity — enough for a
/// 2° honeycomb to read as the real world. Inland seas are separate rings and
/// carve holes through the even-odd rule.
private enum Coastline {
    static let rings: [Ring] = [
        // North America (Alaska → Canada → US → Mexico → Central America)
        Ring([-168, 65.6, -166, 68.9, -156.8, 71.3, -148, 70.3, -141, 69.6, -135, 69.3,
              -128, 70.2, -120, 69.5, -114, 68.3, -108, 68.6, -101.5, 67.8, -96.5, 68.2,
              -94.2, 69.5, -89, 68.9, -85.5, 69.8, -82.5, 66.5, -78, 63.5, -78, 62.4,
              -73.5, 62.3, -69.5, 61, -64.7, 60.3, -61.5, 56.5, -58.5, 54, -57.1, 51.4,
              -61.5, 50.1, -66.5, 49.2, -64.3, 48.9, -64.8, 47.1, -61.5, 45.9, -60, 46.1,
              -63.5, 44.6, -65.8, 43.7, -66.9, 44.8, -70, 43.8, -70.6, 41.6, -74, 40.5,
              -75.5, 38.5, -76, 36.9, -75.5, 35.2, -78, 33.8, -81, 31.5, -81.2, 29.5,
              -80.1, 26.5, -80.4, 25.1, -81.8, 26.2, -82.7, 28, -84.3, 30, -86.5, 30.4,
              -89.5, 30.2, -89.2, 29.1, -91.5, 29.5, -94.5, 29.5, -97.2, 27.7, -97.5, 25.2,
              -97.8, 22.5, -96.2, 19.2, -94.5, 18.2, -91, 18.7, -90.3, 21, -87, 21.5,
              -87.5, 18.5, -88.2, 16, -85, 16, -83.2, 15, -83.6, 11.5, -81.8, 9,
              -79.5, 9.5, -77.4, 8.6, -77.9, 7.2, -78.4, 8.2, -80.5, 7.3, -83.6, 8.4,
              -85.8, 10.9, -87.5, 13, -91.3, 13.9, -94.5, 16.1, -97.8, 16, -101.5, 17.6,
              -105.5, 20.5, -105.7, 22.5, -109, 25.8, -112, 29, -114.7, 31.7, -113.5, 29.2,
              -111.6, 26.5, -109.9, 23.1, -112.1, 24.7, -114.2, 27.8, -115.8, 30.4,
              -117.1, 32.5, -118.5, 34, -120.6, 34.6, -122.5, 37.7, -124.2, 40.4, -124.5, 43,
              -124, 46.2, -124.7, 48.4, -127.5, 50.5, -130, 54.5, -133, 57, -136.5, 58.2,
              -140, 59.8, -146, 60.8, -151.5, 59.2, -154.2, 57.6, -158, 56.5, -162.5, 55,
              -164.5, 54.4, -160, 56.4, -157.5, 58.7, -162, 58.6, -164.8, 60.5, -165.4, 62,
              -164.5, 63.2, -161, 64.5, -166, 64.6]),
        // Hudson Bay (hole)
        Ring([-95, 58.8, -92.8, 57.1, -87.5, 55.5, -82.3, 55.1, -79.5, 51.5, -78.6, 54.5,
              -77, 58.2, -77.8, 60.8, -78.2, 62.3, -86, 63.9, -90.7, 63.5, -94, 61.5]),
        // Newfoundland
        Ring([-59.4, 47.6, -52.6, 47.5, -53, 49.5, -55.8, 51.6, -57.5, 50.5]),
        // Baffin Island
        Ring([-80, 73.7, -70, 70.5, -62, 66.6, -65, 62.5, -72, 62.4, -78, 65, -84, 70, -90, 71.9]),
        // Victoria + Banks Islands
        Ring([-125.5, 71.9, -117.7, 74.5, -105, 73.2, -101.5, 69.5, -110, 68.8, -118, 69.3, -121, 71.3]),
        // Ellesmere + Devon Islands
        Ring([-96, 74.5, -80, 74.5, -76, 76.3, -65, 80.5, -63, 83, -90, 82, -98, 79]),
        // Greenland
        Ring([-73, 78.3, -66, 76, -58, 75.5, -55, 72, -53.5, 68, -50.5, 64.5, -43.6, 59.8,
              -40, 64.5, -35, 66, -22, 70.5, -18.5, 75, -17.5, 79.5, -11, 81.5, -35, 83.5, -62, 82]),
        // Iceland
        Ring([-24.5, 65.5, -22, 66.4, -15, 66.5, -13.5, 65.2, -18.5, 63.4, -22.5, 63.8]),
        // Cuba
        Ring([-84.9, 21.9, -81, 23.2, -77.5, 21.8, -74.2, 20.2, -77.7, 19.9, -80.5, 21.8, -83.2, 22.1]),
        // Hispaniola
        Ring([-74.4, 18.5, -72.8, 19.9, -69.5, 19.6, -68.4, 18.6, -71.5, 17.6, -73.5, 18.2]),
        // South America
        Ring([-77.2, 8.2, -75.5, 10.6, -72, 11.8, -71, 10.8, -68, 10.5, -63, 10.7, -61, 10.2,
              -60, 8.5, -57, 6, -54, 5.9, -51.5, 4.4, -50, 1.8, -48.3, -0.9, -44.5, -2.5,
              -40, -2.9, -37, -4.9, -35.2, -5.5, -34.8, -7.5, -35.5, -9.7, -38.5, -13,
              -39.2, -17.8, -40.9, -22, -43.2, -23, -46.5, -24.1, -48.6, -26.3, -48.7, -28.5,
              -50.3, -30.8, -52.5, -33.5, -54, -34.8, -56.3, -34.9, -57.5, -36.2, -57.5, -38.2,
              -62, -39, -65, -41, -64, -42.5, -65.5, -45, -67.5, -46.5, -66, -48, -68.5, -50.2,
              -68.5, -52.3, -70, -52.8, -68.6, -54.9, -70.5, -55.2, -74, -52, -75.5, -48.5,
              -74, -44, -73.8, -40.5, -73.5, -37, -71.6, -33, -71.4, -28, -70.4, -23.5,
              -70.3, -18.3, -75.5, -15, -77, -12, -79.5, -7.5, -81.3, -4.7, -80, -2, -80.9, -1,
              -79.8, 1.5, -78.6, 2.8, -77.5, 4, -77.4, 6.8]),
        // Eurasia (Iberia → Scandinavia → Arctic Russia → Pacific → SE Asia →
        // India → Arabia → Levant → Turkey → Balkans → Italy → back to Iberia)
        Ring([-5.6, 36, -6.4, 36.8, -8.9, 37, -8.8, 38.7, -9.5, 39.4, -8.9, 41.9, -9.3, 43.1,
              -8, 43.7, -4, 43.4, -1.8, 43.4, -1.2, 46, -2.2, 47.2, -4.7, 48.3, -3.1, 48.8,
              -1.6, 48.6, -1.9, 49.7, 0.2, 49.5, 1.6, 50.9, 3.5, 51.4, 4.8, 52.9, 6.9, 53.5,
              8.6, 53.9, 8.6, 55.5, 8.1, 56.8, 10.5, 57.7, 10.6, 56.2, 10, 55, 10.9, 54.4,
              12.5, 54.4, 14.2, 53.9, 18.5, 54.8, 21.2, 55.2, 21, 56.8, 23.8, 57, 24.2, 58.3,
              23.5, 59.2, 28, 59.5, 26, 60.4, 22.8, 59.9, 21.4, 61, 21.5, 63, 25.4, 65,
              22.2, 65.8, 20, 63.6, 17.5, 62.3, 17.3, 60.6, 18.9, 59.8, 18.1, 59.3, 16.6, 57.9,
              16.4, 56.2, 14.2, 55.4, 12.9, 55.6, 12.7, 56.6, 11.9, 58.1, 11.2, 59, 10.6, 59.9,
              8.5, 58.1, 5.6, 58.8, 5, 60.4, 5, 62, 7.7, 63.3, 10.5, 64.5, 13, 66.5,
              15.5, 68.3, 19, 69.8, 25.8, 71.1, 31, 70.2, 33, 69.3, 41.2, 66.7, 40.5, 64.5,
              44, 66.2, 53.5, 68.7, 59.5, 68.7, 66.8, 69.5, 68.5, 72.8, 71.5, 72.9, 72.5, 69,
              78, 72.3, 82, 73.6, 87, 75.1, 100, 76.5, 104.2, 77.7, 112, 74, 113.5, 73.4,
              127, 73.5, 140, 72.5, 150, 71.2, 160, 70, 171, 69.8, 180, 68.8, 180, 65,
              177, 62.5, 170, 60, 163.5, 59.8, 163, 56.8, 160.5, 54.4, 156.7, 51, 156, 55,
              156.8, 57.8, 160, 61, 154, 59.5, 143, 59.3, 138, 56.5, 137.3, 54, 140.5, 53.3,
              141.2, 52.1, 140.4, 48.5, 138.2, 46.5, 135.5, 43.5, 132, 43.1, 130.7, 42.3,
              129.4, 41, 129.5, 36, 129.3, 35.2, 126.4, 34.4, 126.1, 36.7, 126.6, 37.7,
              125.1, 39.5, 124.4, 40, 121.2, 40.9, 121.2, 38.8, 122, 40.5, 119.2, 39.2,
              117.8, 38.6, 118.8, 37.5, 122.6, 37.4, 120.3, 36, 119.4, 35.1, 120.7, 32.6,
              121.9, 31, 121.9, 29.8, 120.7, 27.9, 119.6, 25.8, 117.8, 24.2, 114.2, 22.3,
              111, 21.4, 110.3, 20.2, 109.7, 21.5, 108, 21.6, 106.7, 20.5, 105.6, 18.9,
              106.6, 17.3, 108.9, 15.3, 109.2, 12.2, 107, 10.4, 105, 8.7, 104.8, 10.4,
              103.2, 10.7, 102.3, 12.2, 100.9, 13.4, 100, 12, 99.2, 9.2, 100.4, 7.3,
              101.3, 6.9, 103.4, 4, 104.2, 1.4, 103.4, 1.3, 101.3, 2.9, 100.4, 5.3, 98.3, 8,
              98.6, 10.5, 97.7, 16.5, 94.3, 16, 94.8, 19.4, 92.3, 20.8, 91.8, 22.4, 90.5, 22.1,
              88.2, 21.7, 86.9, 20.8, 85, 19.3, 82.3, 16.6, 80.2, 15.4, 80.3, 13.1, 79.8, 10.3,
              78.2, 8.9, 77.5, 8.1, 76.3, 9.9, 74.9, 12.8, 73.4, 16, 72.8, 19, 72.6, 21.4,
              70, 20.8, 68.8, 22.3, 70.2, 23, 68.5, 23.6, 67, 24.8, 61.6, 25.2, 57.3, 25.8,
              56.4, 27.1, 54, 26.6, 51.5, 27.9, 50.1, 30.1, 48, 30, 48.5, 28.3, 50.1, 26.7,
              51.6, 25.3, 51.8, 24, 54.2, 24.2, 56.1, 26.2, 56.4, 24.5, 58.8, 23.5, 59.8, 22.4,
              58.5, 20.5, 57.8, 19, 55.5, 17.8, 52.2, 15.6, 48.7, 14, 45, 12.8, 43.5, 12.7,
              42.7, 15.5, 41, 18.5, 39.2, 21.5, 37.2, 24.8, 35.2, 28, 34.9, 29.5, 34.3, 31.3,
              35, 32.8, 35.9, 35.3, 36.2, 36.6, 34.6, 36.8, 32, 36.1, 29.6, 36.2, 27.3, 37,
              26.3, 38.5, 26.2, 40.1, 26, 40.8, 24, 40.7, 22.9, 40.6, 23.4, 39.2, 24, 38,
              23.2, 37, 22.5, 36.4, 21.1, 37.5, 21.1, 38.8, 20, 39.7, 19.4, 41.5, 18.5, 42.4,
              16, 43.5, 14, 45, 13.6, 45.6, 12.3, 45.2, 12.5, 44, 13.9, 42.7, 16, 41.4,
              18.5, 40.2, 17, 39, 16.6, 38.4, 15.6, 38, 16.1, 39.5, 15, 40.2, 13.8, 41.2,
              12.2, 41.8, 10.5, 42.9, 10.2, 43.9, 8.8, 44.4, 7.5, 43.8, 5.3, 43.3, 3.2, 43,
              3.2, 41.9, 0.9, 41, 0, 39.4, -0.4, 38.3, -1.3, 37.5, -2.2, 36.7, -4.4, 36.7]),
        // Black Sea (hole)
        Ring([28, 41.3, 29.2, 41.2, 33.5, 42, 36.5, 41.3, 41.5, 41.5, 40, 43.4, 37.5, 44.7,
              36.5, 45.4, 33.5, 44.5, 32.5, 45.4, 30.7, 46.5, 29.6, 45.2, 28.6, 43.6, 27.9, 42.5]),
        // Caspian Sea (hole)
        Ring([47, 44.5, 49.5, 46.5, 53, 47, 51.3, 45.2, 53, 42, 54, 40, 53.5, 37.3, 50.2, 37.4,
              49, 38.5, 49.5, 40.5, 47.6, 42.5]),
        // Great Britain
        Ring([-5.7, 50.1, -3.5, 50.3, 1.4, 51.2, 1.7, 52.6, 0.3, 53.5, -1.3, 54.9, -2, 55.9,
              -1.8, 57.5, -3.1, 58.6, -5, 58.6, -5.8, 57.2, -5.6, 56, -4.9, 55, -3.1, 54,
              -3, 53.3, -4.6, 53.3, -4.2, 52.2, -5.2, 51.7, -3.2, 51.4, -4.6, 51]),
        // Ireland
        Ring([-6, 52.2, -6.1, 53.5, -5.5, 54.6, -7.3, 55.4, -8.5, 54.3, -10, 53.4, -9.6, 51.6, -8, 51.6]),
        // Sicily, Sardinia, Crete, Cyprus
        Ring([12.4, 38.1, 15.6, 38.3, 15.1, 36.7, 12.4, 37.6]),
        Ring([8.2, 41, 9.8, 41, 9.6, 39.1, 8.4, 39]),
        Ring([23.5, 35.6, 26.3, 35.3, 26.1, 34.9, 24, 34.9]),
        Ring([32.3, 34.8, 34.6, 35.7, 33.9, 34.9, 32.9, 34.6]),
        // Svalbard, Novaya Zemlya, Sakhalin
        Ring([11, 78.5, 16, 76.6, 22, 77.5, 27, 80, 17, 80.3, 11, 79.7]),
        Ring([52, 71.4, 57, 70.6, 61, 73.5, 69, 76.8, 64, 77, 55, 74]),
        Ring([141.9, 45.9, 143.6, 46.5, 143.3, 49.5, 144.6, 48.8, 143, 54, 142.3, 54.3, 142, 51]),
        // Japan: Hokkaido, Honshu + Shikoku, Kyushu
        Ring([140, 41.5, 141.3, 45.4, 145.8, 43.4, 143.3, 42]),
        Ring([130.9, 34.2, 132.5, 35.5, 136, 35.8, 137, 37.5, 139.8, 38.5, 140.3, 41.4,
              141.5, 40.5, 141.9, 38.3, 140.9, 36, 139.8, 35, 138.5, 34.6, 136.8, 34.4,
              135.1, 33.8, 133, 33.2, 132.3, 33.6]),
        Ring([130, 31.3, 131.4, 31.4, 131.9, 33.3, 130.8, 34, 129.6, 33.3]),
        // Taiwan, Hainan, Sri Lanka
        Ring([120.1, 23, 121.5, 25.3, 122, 25, 120.9, 21.9]),
        Ring([108.6, 19.2, 110.5, 20.1, 111, 19.6, 109.6, 18.2]),
        Ring([79.8, 6.4, 79.9, 9.8, 81.9, 7.4, 81.4, 6.2]),
        // Philippines: Luzon, Mindanao
        Ring([120, 16, 120.6, 18.5, 122.2, 18.5, 122.3, 16.5, 124, 12.6, 121.5, 13.8]),
        Ring([122, 7, 126.6, 7.3, 126, 9.8, 123.5, 8.6]),
        // Sumatra, Java, Borneo, Sulawesi, New Guinea
        Ring([95.3, 5.6, 98, 4.2, 103.8, 1, 106, -3, 106, -5.9, 104.5, -5.9, 101, -2.5, 98.5, 1.6]),
        Ring([105.2, -6.8, 108, -6.3, 112.5, -6.9, 114.4, -7.8, 114.4, -8.7, 110, -8.2, 106, -7.4]),
        Ring([109, 1.5, 111, 2, 115.5, 5.2, 117.2, 7, 119.2, 5.1, 118, 1, 116.5, -2, 116, -3.9,
              114.5, -3.9, 111, -3, 110, -1.5]),
        Ring([119.5, -5.5, 119.3, -1, 120.9, 1.3, 125, 1.5, 121.1, 0.6, 123.2, -0.9, 121.3, -1.9,
              123, -4.8, 121, -4.3]),
        Ring([131, -1.4, 134.5, -0.9, 138, -1.6, 141, -2.6, 145, -4.5, 147.5, -6.2, 150.5, -10.5,
              147, -9.9, 143.5, -9, 141, -9.2, 138.5, -8.3, 137.7, -5.2, 133.7, -4, 132, -2.6]),
        // Australia
        Ring([114.1, -21.8, 114.9, -29, 115, -34.3, 117.9, -35.1, 123.6, -33.9, 126, -32.3,
              131, -31.5, 134.2, -32.9, 135.9, -34.8, 137.8, -33, 138.1, -35.6, 139.6, -37.2,
              141.5, -38.4, 144.9, -37.9, 146.4, -39.1, 150, -37.5, 151.3, -33.8, 153.1, -30.5,
              153.6, -28.2, 153, -25, 150.8, -22.5, 148.9, -20.2, 146.2, -18.5, 145.3, -15,
              142.5, -10.7, 141.6, -13, 141.5, -16.5, 140.7, -17.5, 139.2, -17.3, 135.8, -15,
              136.9, -12.3, 132.6, -11.4, 130.8, -12.4, 129.4, -14.9, 127, -13.9, 125, -15,
              123.5, -17.2, 122.2, -18.2, 120, -19.8, 117, -20.6]),
        // Tasmania, New Zealand
        Ring([144.6, -40.7, 148.3, -40.9, 148.3, -42.2, 146.9, -43.6, 145.2, -42.2]),
        Ring([172.7, -34.4, 174.9, -37, 178.5, -37.7, 177, -39.3, 175, -41.6, 174.6, -39.9,
              173.8, -39.3, 174.5, -37]),
        Ring([172.7, -40.5, 174.3, -41.7, 172.8, -43.8, 171.2, -44.5, 169, -46.7, 166.5, -46,
              168.4, -44, 171.3, -41.8]),
        // Africa
        Ring([-5.9, 35.8, -2, 35.1, 3, 36.8, 10.2, 37.2, 11.1, 36.9, 10.1, 34.2, 11.1, 33.3,
              15.2, 32.3, 19.8, 30.6, 20.1, 32.1, 23, 32.7, 25.2, 31.6, 29.9, 31.2, 32.3, 31.3,
              32.5, 29.9, 34.2, 27.8, 33.9, 27, 35.6, 23.1, 37.2, 19.6, 38.6, 17.9, 39.7, 15.1,
              41.7, 13.4, 43.3, 11.8, 44.8, 10.4, 51.2, 11.8, 51, 10.4, 48.9, 5.3, 46.1, 2.1,
              41.5, -1.7, 39.2, -4.7, 39.3, -6.8, 40.4, -10.5, 40.6, -15, 36.9, -17.8,
              34.8, -19.8, 35.5, -22, 32.9, -25.9, 32.4, -28.6, 31, -29.9, 27.9, -33, 25.6, -34,
              22.1, -34.1, 20, -34.8, 18.4, -34.1, 18.1, -32.3, 16.5, -28.6, 15.2, -26.7,
              14.5, -22.9, 11.8, -17.3, 13.4, -12.5, 13.2, -8.8, 12.2, -6, 11.1, -3.9, 9.3, -1,
              9.8, 3, 8.5, 4.5, 6, 4.3, 3.4, 6.4, -0.2, 5.5, -4.1, 5.2, -7.5, 4.4, -10.5, 6.5,
              -13.3, 8.5, -15.1, 11, -16.8, 13.2, -17.5, 14.7, -16.5, 16.5, -16.1, 19.4,
              -17.1, 21, -14.9, 24, -13.1, 27.5, -9.8, 29.8, -9.7, 31.2, -6.8, 34]),
        // Madagascar
        Ring([49.3, -12, 50.5, -15.3, 49.5, -17.9, 48, -22.5, 47.1, -24.9, 45.2, -25.5,
              43.7, -23.5, 44.2, -20, 44.4, -16.2, 46.3, -15.7, 47.9, -13.6]),
    ]
}

// MARK: - Country centres

/// Approximate centres (latitude, longitude) for the countries VPN panels
/// actually use. Everything not in the table is absent rather than misplaced.
private enum CountryGeo {
    static let centers: [String: (lat: Double, lon: Double)] = [
        "RU": (58, 60), "US": (39, -98), "CA": (56, -106), "MX": (23, -102), "BR": (-10, -52),
        "AR": (-34, -64), "CL": (-33, -71), "CO": (4.5, -74), "PE": (-10, -76),
        "GB": (53, -1.5), "IE": (53.4, -8), "FR": (46.5, 2.4), "DE": (51, 10), "NL": (52.2, 5.3),
        "BE": (50.6, 4.6), "LU": (49.8, 6.1), "CH": (46.8, 8.2), "AT": (47.6, 14.1),
        "IT": (42.8, 12.5), "ES": (40.4, -3.7), "PT": (39.5, -8), "DK": (56, 9.5),
        "NO": (61, 9), "SE": (62, 15), "FI": (63, 26), "IS": (64.9, -19), "EE": (58.8, 25.5),
        "LV": (56.9, 24.6), "LT": (55.3, 24), "PL": (52, 19.5), "CZ": (49.8, 15.5),
        "SK": (48.7, 19.5), "HU": (47.2, 19.5), "SI": (46.1, 14.8), "HR": (45.3, 16),
        "RS": (44, 20.8), "BA": (44, 17.8), "ME": (42.8, 19.3), "AL": (41.1, 20),
        "MK": (41.6, 21.7), "GR": (39.3, 22), "BG": (42.7, 25.4), "RO": (45.9, 25),
        "MD": (47, 28.5), "UA": (49, 32), "BY": (53.5, 28), "TR": (39, 35), "CY": (35, 33),
        "GE": (42, 43.5), "AM": (40.2, 44.8), "AZ": (40.3, 47.7), "KZ": (48, 68),
        "UZ": (41.4, 64.5), "KG": (41.4, 74.8), "TJ": (38.8, 71), "MN": (46.8, 103.8),
        "IL": (31.5, 34.9), "JO": (31, 36.3), "LB": (33.9, 35.9), "SA": (24, 45),
        "AE": (24, 54), "QA": (25.3, 51.2), "BH": (26, 50.5), "KW": (29.3, 47.6),
        "OM": (21, 57), "IR": (32.5, 54), "PK": (30, 70), "IN": (21, 78), "NP": (28.3, 84),
        "BD": (23.7, 90.3), "LK": (7.8, 80.7), "CN": (35, 105), "HK": (22.3, 114.2),
        "MO": (22.2, 113.5), "TW": (23.7, 121), "KR": (36.5, 128), "JP": (36.3, 138.5),
        "VN": (16, 106), "TH": (15, 101), "KH": (12.5, 105), "LA": (18.5, 103),
        "MM": (21, 96), "MY": (4, 102), "SG": (1.35, 103.8), "ID": (-2, 118),
        "PH": (12, 122), "AU": (-25, 134), "NZ": (-41, 173),
        "EG": (26.5, 30), "MA": (32, -6), "TN": (34, 9.5), "NG": (9.5, 8), "KE": (0.2, 37.9),
        "ZA": (-29, 24),
    ]
}

// MARK: - Traffic sparkline

/// The session's traffic curve: down as a filled accent area, up as a thin
/// ink line, normalized together to the window's peak (floored at 1 KB/s so
/// idle sessions keep their shape instead of flattening into the baseline).
/// A static Canvas — it re-renders only when a new sample lands.
private struct SparklineCanvas: View {
    let samples: [TrafficSample]

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            guard w > 2, h > 2, samples.count >= 2 else { return }

            let peak = max(samples.map { max($0.down, $0.up) }.max() ?? 0, 1024)
            func y(_ v: Int64) -> CGFloat {
                h - 1.5 - (h - 4) * CGFloat(Double(v) / Double(peak))
            }
            let step = w / CGFloat(samples.count - 1)
            func x(_ i: Int) -> CGFloat { CGFloat(i) * step }

            // Down: filled area with a fading top — the mass of the traffic.
            var area = Path()
            area.move(to: CGPoint(x: 0, y: h - 1))
            for (i, s) in samples.enumerated() {
                area.addLine(to: CGPoint(x: x(i), y: y(s.down)))
            }
            area.addLine(to: CGPoint(x: w, y: h - 1))
            area.closeSubpath()
            ctx.clip(to: Path(CGRect(x: 0, y: 0, width: w, height: h)))
            ctx.fill(area, with: .linearGradient(
                Gradient(colors: [Theme.accent.opacity(0.30),
                                  Theme.accent.opacity(0.06)]),
                startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: h)))

            // Down stroke on top of its own area.
            var downLine = Path()
            for (i, s) in samples.enumerated() {
                let p = CGPoint(x: x(i), y: y(s.down))
                i == 0 ? downLine.move(to: p) : downLine.addLine(to: p)
            }
            ctx.stroke(downLine, with: .color(Theme.accent.opacity(0.85)),
                       style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))

            // Up: a quiet companion line.
            var upLine = Path()
            for (i, s) in samples.enumerated() {
                let p = CGPoint(x: x(i), y: y(s.up))
                i == 0 ? upLine.move(to: p) : upLine.addLine(to: p)
            }
            ctx.stroke(upLine, with: .color(Theme.textLo.opacity(0.55)),
                       style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))

            // Baseline hairline — grounds the curve.
            ctx.stroke(Path(CGRect(x: 0, y: h - 1, width: w, height: 1)),
                       with: .color(Theme.stroke))

            // Latest-value bead on the down line.
            if let last = samples.last {
                let bead = CGPoint(x: w - 2, y: y(last.down))
                ctx.fill(Path(ellipseIn: CGRect(x: bead.x - 2, y: bead.y - 2,
                                                width: 4, height: 4)),
                         with: .color(Theme.accent))
            }
        }
    }
}

/// The session's traffic curve on its own (the main window's traffic strip):
/// a quiet baseline until the engine has produced two samples.
struct TrafficSparkline: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        let samples = Array(state.trafficHistory.suffix(AppState.trafficHistoryCapacity))
        ZStack {
            if samples.count >= 2 {
                SparklineCanvas(samples: samples)
                    .transition(.opacity)
            } else {
                Capsule()
                    .fill(Theme.stroke)
                    .frame(height: 1)
                    .transition(.opacity)
            }
        }
        .animation(Theme.spring, value: samples.count >= 2)
    }
}
