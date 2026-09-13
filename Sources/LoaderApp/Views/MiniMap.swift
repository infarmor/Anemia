import SwiftUI
import LoaderCore

/// The world tile — the main window's right column, now full-height:
///
///  * the map itself: dot-matrix landmass on a 3° grid in quiet ink, drawn
///    ONCE into a static layer; the animated overlay above it repaints only
///    the handful of live marks each frame, so 30 fps costs a dozen
///    ellipses, not two thousand;
///  * hovering the map names what a dot stands for: the nearest country dot
///    lights up and a small chip names it — server countries carry their
///    park size, home and exit identify themselves;
///  * a live traffic sparkline below the map — the session's down/up curve,
///    drawn from the engine's stats samples — filling the space the old tile
///    left empty;
///  * a caption strip: named exit on the left, the reach of the server park
///    on the right.
///
/// Geography is best-effort and honest about it: a server's country comes
/// from the flag emoji in its name (how panels almost always label nodes),
/// the home country from the physical-interface geolocation in AppState.
/// Servers without a flag simply don't appear — the map never guesses.
struct MiniMap: View {
    @EnvironmentObject var state: AppState

    /// Everything the canvases need, computed ONCE per body evaluation —
    /// never per animation frame (the old code re-scanned every server name
    /// 30 times a second inside the drawing closure).
    // fileprivate: MarkerCanvas (a separate struct in this file) consumes it.
    fileprivate struct Snapshot {
        var countries: [(cc: String, count: Int)] = []
        var selected: String?
        var home: String?
        var connected = false
        var connecting = false
    }

    /// Server countries the map can actually place (known flag + table entry),
    /// with their server counts.
    private var snapshot: Snapshot {
        var counts: [String: Int] = [:]
        for s in state.allServers {
            if let cc = state.serverCountry(s.name)?.uppercased(),
               CountryGeo.centers[cc] != nil {
                counts[cc, default: 0] += 1
            }
        }
        // The selected server's country even if unplaceable — the caption row
        // distinguishes "selected but unknown" from "nothing selected".
        let selected = state.selectedServer
            .flatMap { state.serverCountry($0.name)?.uppercased() }
        return Snapshot(
            countries: counts.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 },
            selected: selected,
            home: state.homeCountry?.uppercased(),
            connected: state.isConnected,
            connecting: state.connection == .connecting)
    }

    /// The reach of the park — placed countries, not raw server count.
    private func mappableCountryCount(in snap: Snapshot) -> Int {
        snap.countries.count
    }

    /// The country currently under the cursor (or nil). Stored as a code, not
    /// a point: a hover that only changed pixels would re-render the whole
    /// tile on every mouse move — this way it re-renders when the answer
    /// changes.
    @State private var hoverCountry: String?

    var body: some View {
        // One scan of the server list per state change, shared by every row
        // below — the tile never re-derives its data four times per render.
        let snap = snapshot
        return VStack(spacing: 8) {
            map(snap)
            hairline
            exitRow(snap)
            trafficSection(snap)
            countsRow(snap)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .softCard(shadow: false)
        .help(hint(snap))
        .animation(Theme.spring, value: snap.connected)
    }

    // MARK: - Map layers

    private func map(_ snap: Snapshot) -> some View {
        let animating = snap.connected || snap.connecting
        return Group {
            if animating {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
                    layers(snap: snap, date: ctx.date)
                }
            } else {
                // A static map (nothing selected / offline) draws once and
                // costs nothing. Hover still works — it re-renders only when
                // the hovered country changes.
                layers(snap: snap, date: nil)
            }
        }
        // Aspect-fit, not a fixed height: the tile pins the width (240 in the
        // two-column layout), so fitting to the 2:1 equirectangular ratio is
        // safe here and the map can never collapse to a sliver — the height
        // follows the width.
        .aspectRatio(2, contentMode: .fit)
        .frame(maxWidth: .infinity)
    }

    /// Static land + animated markers, composed so the dot matrix is drawn
    /// exactly once per state change, while only the live markers repaint.
    /// Also owns the hover interaction: cursor position → nearest country.
    private func layers(snap: Snapshot, date: Date?) -> some View {
        GeometryReader { geo in
            ZStack {
                LandCanvas(size: geo.size)
                MarkerCanvas(size: geo.size, snap: snap, date: date,
                             hover: hoverCountry)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.stroke))
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    hoverCountry = Self.nearestCountry(to: point,
                                                       size: geo.size, snap: snap)
                case .ended:
                    hoverCountry = nil
                }
            }
            .overlay(alignment: .topLeading) {
                if let cc = hoverCountry, let label = Self.hoverLabel(cc, snap: snap) {
                    TooltipChip(label: label)
                        // Anchor over the dot's projected position, nudged to
                        // stay inside the tile.
                        .offset(Self.tooltipOffset(cc, size: geo.size))
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    /// The placeable country whose projected dot lies closest to `point`,
    /// within a 10 pt grab radius. Considers server countries, home, and the
    /// selected exit — everything the map actually draws.
    fileprivate static func nearestCountry(to point: CGPoint, size: CGSize,
                                           snap: Snapshot) -> String? {
        func project(_ c: (lat: Double, lon: Double)) -> CGPoint {
            CGPoint(x: (c.lon + 180) / 360 * size.width,
                    y: (90 - c.lat) / 180 * size.height)
        }
        var candidates: [(cc: String, p: CGPoint)] = []
        for (cc, _) in snap.countries {
            if let c = CountryGeo.centers[cc] { candidates.append((cc, project(c))) }
        }
        if let h = snap.home, let c = CountryGeo.centers[h] {
            candidates.append((h, project(c)))
        }
        guard !candidates.isEmpty else { return nil }
        var best: (cc: String, d: CGFloat)?
        for cand in candidates {
            let dx = cand.p.x - point.x, dy = cand.p.y - point.y
            let d = (dx * dx + dy * dy).squareRoot()
            if d < 10, best == nil || d < best!.d { best = (cand.cc, d) }
        }
        return best?.cc
    }

    /// Flag + name (+ park size for server countries) for the hover chip.
    private static func hoverLabel(_ cc: String, snap: Snapshot) -> String? {
        guard CountryGeo.centers[cc] != nil else { return nil }
        let flag = Self.flagEmoji(cc)
        let name = Locale.current.localizedString(forRegionCode: cc) ?? cc
        if let entry = snap.countries.first(where: { $0.cc == cc }) {
            return "\(flag) \(name) · \(entry.count) \(entry.count == 1 ? "server" : "servers")"
        }
        if cc == snap.home { return "\(flag) \(name) · home" }
        if cc == snap.selected { return "\(flag) \(name) · exit" }
        return "\(flag) \(name)"
    }

    /// Where the chip sits relative to the tile's top-leading corner:
    /// just above the dot, clamped into the tile.
    private static func tooltipOffset(_ cc: String, size: CGSize) -> CGSize {
        guard let c = CountryGeo.centers[cc] else { return .zero }
        let p = CGPoint(x: (c.lon + 180) / 360 * size.width,
                        y: (90 - c.lat) / 180 * size.height)
        // Clamp horizontally (chip ≈ 84 pt wide) and keep a top margin.
        let chipW: CGFloat = 88
        let cx = max(p.x - 40, 4)
        let clampedX = min(cx, max(4, size.width - chipW))
        let clampedY = max(p.y - 30, 2)
        return CGSize(width: clampedX, height: clampedY)
    }

    /// Regional-indicator flag for an ISO code (inverse of the name parser).
    /// The `count == 2` + letter guard keeps a stray non-A–Z scalar from
    /// mapping into the emoji plane and producing garbage glyphs.
    private static func flagEmoji(_ cc: String) -> String {
        guard cc.count == 2 else { return "" }
        return String(cc.unicodeScalars.compactMap { scalar in
            (65...90).contains(scalar.value)
                ? UnicodeScalar(0x1F1E6 - 65 + scalar.value).map(Character.init)
                : nil
        })
    }

    // MARK: - Caption rows

    private var hairline: some View {
        Divider().overlay(Theme.stroke)
    }

    /// Where you exit (dot mirrors the map's exit color) and, when known,
    /// where you enter from — the tile's answer to "am I there yet?".
    private func exitRow(_ snap: Snapshot) -> some View {
        HStack(spacing: 5) {
            if let cc = snap.selected {
                Circle()
                    .fill(state.isConnected ? Theme.accent : Theme.textLo.opacity(0.5))
                    .frame(width: 5, height: 5)
                Text("\(Self.flagEmoji(cc)) \(countryName(cc))")
                    .font(Theme.ui(11, .medium))
                    .foregroundStyle(Theme.textHi)
                    .lineLimit(1)
                if let home = state.homeCountry?.uppercased(), home != cc,
                   state.isConnected {
                    Text("← \(Self.flagEmoji(home))")
                        .font(Theme.ui(11))
                        .foregroundStyle(Theme.textLo)
                }
            } else {
                // "Selected but country unknown" is a different state from
                // "nothing selected" — don't ask the user to pick again.
                Text(state.selectedServer == nil
                     ? "Choose a server to place your exit"
                     : "Server's exit country unknown")
                    .font(Theme.ui(11)).foregroundStyle(Theme.textLo)
            }
            Spacer(minLength: 4)
        }
    }

    // MARK: - Live traffic sparkline

    /// The session's down/up curve, from the engine's stats samples — the
    /// column's filler and its most honest gauge: a flat line under load says
    /// more than any label. Stretches to absorb whatever height the map
    /// column has left.
    private func trafficSection(_ snap: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(snap.connected ? Theme.accent : Theme.textLo.opacity(0.35))
                    .frame(width: 5, height: 5)
                Text(snap.connected ? "Live traffic" : "Traffic")
                    .font(Theme.ui(10, .semibold))
                    .foregroundStyle(Theme.textLo)
                Spacer(minLength: 4)
                if snap.connected {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.down")
                            .font(Theme.metric(9)).foregroundStyle(Theme.accent)
                        Text(Format.speed(state.downlinkSpeed))
                            .font(Theme.metric(10))
                            .foregroundStyle(Theme.textHi)
                    }
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up")
                            .font(Theme.metric(9)).foregroundStyle(Theme.warn)
                        Text(Format.speed(state.uplinkSpeed))
                            .font(Theme.metric(10))
                            .foregroundStyle(Theme.textLo)
                    }
                }
            }
            sparkline
        }
    }

    @ViewBuilder private var sparkline: some View {
        let samples = state.trafficHistory.suffix(AppState.trafficHistoryCapacity)
        if samples.count >= 2 {
            SparklineCanvas(samples: Array(samples))
                .frame(minHeight: 34, maxHeight: .infinity)
                .animation(Theme.spring, value: state.trafficHistory.count)
        } else {
            // A quiet promise, not an empty box: the curve appears the moment
            // the engine produces its second sample.
            VStack(spacing: 4) {
                Image(systemName: "chart.xyaxis.line")
                    .font(Theme.ui(13)).foregroundStyle(Theme.textLo.opacity(0.5))
                Text("Traffic curve appears while connected")
                    .font(Theme.ui(10)).foregroundStyle(Theme.textLo.opacity(0.7))
            }
            .frame(maxWidth: .infinity, minHeight: 34, maxHeight: .infinity)
        }
    }

    /// The reach of the park — placed countries, not raw server count.
    private func countsRow(_ snap: Snapshot) -> some View {
        HStack(spacing: 4) {
            Spacer(minLength: 4)
            Text("\(mappableCountryCount(in: snap)) countries · \(state.allServers.count) servers")
                .font(Theme.ui(11))
                .foregroundStyle(Theme.textLo)
                .lineLimit(1)
        }
    }

    private func countryName(_ cc: String) -> String {
        Locale.current.localizedString(forRegionCode: cc) ?? cc
    }

    private func hint(_ snap: Snapshot) -> String {
        var lines: [String] = []
        if let cc = snap.selected { lines.append("Exit: \(cc) — \(countryName(cc))") }
        if let home = state.homeCountry { lines.append("Home: \(home) — \(countryName(home))") }
        lines.append("Hover a dot to name it · countries come from flag emoji in server names")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Hover chip

/// The small floating label that names a hovered dot. Hit-testing disabled:
/// the chip must never steal the hover that summoned it.
private struct TooltipChip: View {
    let label: String
    var body: some View {
        Text(label)
            .font(Theme.ui(10, .medium))
            .foregroundStyle(Theme.textHi)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(Theme.cardHi, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Theme.stroke))
            .shadow(color: Theme.shadowColor, radius: 4, y: 2)
            .fixedSize()
    }
}

// MARK: - Static layer (landmass)

/// The landmass dot matrix: drawn whenever its size or the theme changes,
/// and never while the animation ticks. Also carries the ocean wash.
private struct LandCanvas: View {
    let size: CGSize

    var body: some View {
        Canvas { ctx, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height

            // Ocean: a barely-there vertical wash so the tile reads as a
            // map, not a field of scattered dots.
            ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: h)),
                     with: .linearGradient(
                        Gradient(colors: [Theme.bgTop.opacity(0.30),
                                          Theme.bgBottom.opacity(0.45)]),
                        // GraphicsContext gradients take CGPoints, not UnitPoints.
                        startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: h)))

            /// Normalised cell centre (0…1) → canvas point.
            func pos(norm: CGPoint) -> CGPoint {
                CGPoint(x: norm.x * w, y: norm.y * h)
            }
            /// Deterministic per-cell jitter — a printed-dot halftone, not a
            /// laser grid. Same cell, same size every frame (a random radius
            /// would shimmer). Returns −0.5…0.5 exactly: the raw signed
            /// fractional part spans (−1, 1) (s = −12.7 → −0.7), so it is
            /// folded onto [0, 1) before centering.
            func jitter(_ n: CGPoint) -> CGFloat {
                let s = sin(n.x * 127.1 + n.y * 311.7) * 43_758.5453
                let fract = s - s.rounded(.towardZero)        // (−1, 1)
                return CGFloat(abs(fract) - 0.5)              // [−0.5, 0.5)
            }

            // Landmass — quiet dot matrix with organic per-cell size wobble.
            // The 3° grid resolves the coarse coastline polygons into crisp
            // recognisable continents at any tile width.
            let baseR = min(w, h) * 0.010
            for cell in WorldDots.cells {
                let p = pos(norm: cell)
                let r = baseR * (1 + 0.35 * jitter(cell))
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r,
                                                width: r * 2, height: r * 2)),
                         with: .color(Theme.mapLand))
            }
        }
        .frame(width: size.width, height: size.height)
        // Batch the two thousand ellipses into one GPU layer: a state change
        // re-render stays off the CPU rasterizer's critical path.
        .drawingGroup()
    }
}

// MARK: - Animated layer (markers + route)

/// Live markers: home, server countries, the selected exit and its route.
/// Everything here is cheap by design — a dozen shapes per frame.
private struct MarkerCanvas: View {
    let size: CGSize
    let snap: MiniMap.Snapshot
    let date: Date?
    let hover: String?

    var body: some View {
        Canvas { ctx, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height

            func pos(lat: Double, lon: Double) -> CGPoint {
                CGPoint(x: (lon + 180) / 360 * w,
                        y: (90 - lat) / 180 * h)
            }
            func dot(_ center: CGPoint, radius: CGFloat, _ color: Color) {
                ctx.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                width: radius * 2, height: radius * 2)),
                         with: .color(color))
            }
            func ring(_ center: CGPoint, radius: CGFloat, _ color: Color,
                      dash: [CGFloat] = [2, 2]) {
                var path = Path()
                path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                           width: radius * 2, height: radius * 2))
                ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1, dash: dash))
            }

            // Server countries — one muted dot each, sized by the park it
            // stands for (log scale: 1 → base, 100 → base + 2.2 pt).
            for (cc, count) in snap.countries where cc != snap.selected {
                guard let c = CountryGeo.centers[cc] else { continue }
                let r = 2.0 + min(2.2, log2(Double(count + 1)) - 1)
                dot(pos(lat: c.lat, lon: c.lon), radius: r, Theme.textLo.opacity(0.75))
            }

            // Home country: the origin of every arc — a solid ink dot with
            // a faint ring, so "where I am" reads without a legend.
            if let home = snap.home, let c = CountryGeo.centers[home] {
                let hp = pos(lat: c.lat, lon: c.lon)
                ctx.stroke(Path(ellipseIn: CGRect(x: hp.x - 4.4, y: hp.y - 4.4,
                                                  width: 8.8, height: 8.8)),
                           with: .color(Theme.textHi.opacity(0.35)), lineWidth: 1)
                dot(hp, radius: 2.4, Theme.textHi)
            }

            // Selected exit in terracotta — layered halos so it reads as
            // "the" dot at a glance — and, while connected, the arc from home.
            guard let cc = snap.selected, let c = CountryGeo.centers[cc] else { return }
            let p = pos(lat: c.lat, lon: c.lon)
            if snap.connecting {
                // Radar sweep: an expanding, fading ring while dialing —
                // the map tells you something is in progress, not just
                // a static dot.
                if let date {
                    let cycle = 1.5
                    let t = CGFloat(date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: cycle)) / CGFloat(cycle)
                    dot(p, radius: 4 + 6 * t, Theme.accent.opacity(0.30 * (1 - t)))
                }
                dot(p, radius: 3.0, Theme.accent.opacity(0.8))
            } else if snap.connected {
                // Breathing halo: one wide ring whose size and opacity pulse
                // gently (2.4 s period) — the mark is alive without strobing.
                if let date {
                    let cycle = 2.4
                    let phase = date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: cycle) / cycle
                    let breathe = CGFloat(0.5 + 0.5 * sin(phase * 2 * .pi))
                    dot(p, radius: 5.5 + 2.5 * breathe, Theme.accent.opacity(0.22 - 0.10 * breathe))
                }
                dot(p, radius: 5.0, Theme.accent.opacity(0.18))
                dot(p, radius: 3.0, Theme.accent)
            } else {
                dot(p, radius: 3.0, Theme.accent.opacity(0.55))
            }

            // Country code beside the exit — the flight-map convention:
            // the mark names itself, no legend needed.
            let codeColor: Color = snap.connected ? Theme.accent : Theme.textLo
            ctx.draw(Text(cc)
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(codeColor),
                     at: CGPoint(x: min(max(p.x + 8, 14), w - 14), y: p.y))

            // Hover highlight: a dashed halo around whatever the cursor is
            // touching, in the same ink the dot itself carries.
            if let hcc = hover, let hc = CountryGeo.centers[hcc] {
                ring(pos(lat: hc.lat, lon: hc.lon), radius: 6.5, Theme.textHi.opacity(0.5))
            }

            guard snap.connected, let home = snap.home,
                  let hc = CountryGeo.centers[home], home != cc else { return }
            let from = pos(lat: hc.lat, lon: hc.lon)
            // Flight-map arc: lift the control point toward the pole
            // in proportion to the span, so short hops stay flat and
            // long ones sweep. The dashes march toward the exit so
            // the route reads as live traffic, not a static wire —
            // and the stroke carries a gradient that fades in from
            // the origin and burns full terracotta at the exit.
            let midX = (from.x + p.x) / 2
            let span = abs(p.x - from.x) + abs(p.y - from.y)
            let ctrl = CGPoint(x: midX, y: min(from.y, p.y) - span * 0.22)
            var path = Path()
            path.move(to: from)
            path.addQuadCurve(to: p, control: ctrl)
            let phase = date.map { CGFloat($0.timeIntervalSinceReferenceDate * -10) } ?? 0
            ctx.stroke(path,
                       with: .linearGradient(
                           Gradient(colors: [Theme.accent.opacity(0.15),
                                             Theme.accent.opacity(0.8)]),
                       startPoint: from, endPoint: p),
                       style: StrokeStyle(lineWidth: 1.4, lineCap: .round,
                                           dash: [4, 3], dashPhase: phase))

            // The packet: a small dot riding the arc home → exit, fading in
            // and out at the ends — the route carries visible traffic, not
            // just marching dashes.
            if let date {
                let cycle = 2.6
                var t = CGFloat(date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: cycle)) / CGFloat(cycle)
                t = t * t * (3 - 2 * t) // smoothstep: eases both ends
                let u = 1 - t
                // Quadratic-bezier interpolation, spelled out per axis: a
                // single combined expression defeats the type-checker here.
                let bezier = { (a: CGFloat, c: CGFloat, b: CGFloat) -> CGFloat in
                    u * u * a + 2 * u * t * c + t * t * b
                }
                let point = CGPoint(
                    x: bezier(from.x, ctrl.x, p.x),
                    y: bezier(from.y, ctrl.y, p.y))
                dot(point, radius: 1.8,
                    Theme.accent.opacity(0.85 * CGFloat(sin(Double(t) * .pi))))
            }
        }
    }
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

// MARK: - Landmass

/// Coarse world: land cell centres as normalised points, sampled once from
/// hand-drawn coastline polygons. Abstract by design — this is a status
/// glyph, not a survey instrument.
private enum WorldDots {
    static let cells: [CGPoint] = {
        var pts: [CGPoint] = []
        for row in 0..<60 {
            let lat = 90 - Double(row) * 3 - 1.5
            for col in 0..<120 {
                let lon = -180 + Double(col) * 3 + 1.5
                if landmasses.contains(where: { $0.contains(lat: lat, lon: lon) }) {
                    pts.append(CGPoint(x: (lon + 180) / 360, y: (90 - lat) / 180))
                }
            }
        }
        return pts
    }()

    /// Coastline polygons as flat [lon, lat, lon, lat, …] rings.
    private static let landmasses: [Landmass] = [
        // North + Central America
        Landmass([-168, 66, -140, 70, -125, 72, -110, 73, -95, 74, -80, 73,
                  -62, 60, -55, 52, -65, 45, -75, 40, -80, 32, -81, 25,
                  -90, 29, -97, 26, -105, 20, -95, 15, -84, 10, -78, 8,
                  -83, 15, -95, 17, -107, 23, -115, 30, -125, 40, -130, 55,
                  -140, 60, -150, 60, -165, 60]),
        // Greenland
        Landmass([-58, 60, -45, 60, -25, 70, -20, 76, -30, 83, -55, 82, -68, 76]),
        // South America
        Landmass([-78, 8, -70, 10, -60, 10, -50, 0, -42, -3, -35, -8, -38, -15,
                  -48, -25, -55, -35, -62, -40, -65, -50, -68, -55, -73, -52,
                  -72, -40, -71, -30, -70, -18, -75, -14, -80, -5, -80, 2]),
        // Eurasia (Europe + Middle East + Siberia + India + SE Asia, one ring)
        Landmass([-10, 36, -9, 43, -2, 44, -4, 48, 0, 50, 4, 52, 7, 54, 8, 58,
                  11, 58, 14, 68, 20, 70, 28, 71, 30, 66, 40, 68, 55, 70,
                  70, 73, 85, 76, 100, 77, 115, 74, 130, 72, 140, 72,
                  155, 68, 170, 68, 179, 66, 178, 62, 163, 58, 155, 52,
                  140, 52, 135, 48, 130, 42, 127, 35, 121, 37, 120, 32,
                  122, 28, 115, 22, 108, 18, 105, 10, 100, 6, 98, 12,
                  94, 16, 90, 22, 88, 20, 82, 16, 78, 8, 74, 12, 72, 20,
                  66, 24, 60, 25, 57, 26, 52, 26, 48, 29, 44, 32, 36, 36,
                  35, 30, 32, 30, 28, 31, 20, 32, 12, 33, 10, 44, 3, 43,
                  -2, 40, -6, 36]),
        // Arabia
        Landmass([35, 30, 38, 25, 43, 13, 45, 12, 50, 13, 55, 17, 58, 22,
                  57, 25, 52, 26, 48, 29, 44, 32, 39, 33]),
        // Africa
        Landmass([-17, 15, -16, 22, -12, 28, -6, 36, 0, 37, 10, 37, 12, 33,
                  20, 32, 25, 32, 32, 31, 35, 25, 38, 18, 43, 12, 48, 11,
                  51, 10, 45, 2, 41, -3, 40, -12, 35, -20, 33, -26, 26, -34,
                  20, -35, 16, -29, 12, -17, 9, -2, 9, 4, 2, 6, -8, 4,
                  -13, 8]),
        // British Isles
        Landmass([-10, 51, -2, 51, 0, 53, -1, 56, -5, 58, -7, 56, -6, 54]),
        // Iceland
        Landmass([-24, 64, -14, 65, -14, 66, -22, 66]),
        // Japan
        Landmass([131, 31, 136, 35, 141, 42, 145, 44, 142, 44, 140, 36, 135, 33]),
        // Indonesia / Malay archipelago band
        Landmass([95, 5, 105, 0, 110, -6, 120, -9, 130, -8, 140, -8,
                  141, -4, 132, -3, 120, -2, 110, 0, 100, 4]),
        // Philippines
        Landmass([120, 6, 124, 12, 122, 18, 118, 10]),
        // Australia
        Landmass([114, -22, 114, -34, 118, -35, 124, -33, 130, -32, 137, -35,
                  140, -38, 147, -38, 150, -37, 153, -28, 153, -25, 146, -19,
                  142, -11, 137, -12, 132, -11, 126, -14, 122, -18]),
        // New Zealand
        Landmass([167, -46, 173, -43, 175, -41, 178, -38, 174, -38, 170, -43]),
        // Madagascar
        Landmass([43, -12, 50, -15, 50, -25, 45, -25, 43, -20]),
    ]
}

/// One coastline ring with an even-odd point-in-polygon test.
private struct Landmass {
    private let lats: [Double]
    private let lons: [Double]

    /// Flat ring authored as [lon, lat, lon, lat, …] — longitudes first, the
    /// natural order when tracing a coastline on a map.
    init(_ ring: [Double]) {
        var l: [Double] = [], o: [Double] = []
        var i = 0
        while i + 1 < ring.count {
            o.append(ring[i]); l.append(ring[i + 1]); i += 2
        }
        lats = l; lons = o
    }

    func contains(lat: Double, lon: Double) -> Bool {
        var inside = false
        var j = lats.count - 1
        for i in 0..<lats.count {
            let yi = lons[i], yj = lons[j]          // "y" = longitude axis
            let xi = lats[i], xj = lats[j]          // "x" = latitude axis
            // Ray casting across the ring; naming swapped on purpose —
            // the classic even-odd test, cast east along the longitude.
            if ((yi > lon) != (yj > lon)) &&
               (lat < (xj - xi) * (lon - yi) / (yj - yi) + xi) {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}

// MARK: - Country centres

/// Approximate centres for the countries VPN panels actually use, as
/// (latitude, longitude). Everything not in the table is simply absent from
/// the map rather than misplaced.
private enum CountryGeo {
    static let centers: [String: (lat: Double, lon: Double)] = [
        "RU": (60, 90), "US": (39, -98), "DE": (51, 10), "NL": (52.2, 5.3),
        "GB": (54, -2), "FR": (46.5, 2.4), "FI": (64, 26), "SE": (62, 15),
        "NO": (62, 10), "TR": (39, 35), "AE": (24, 54), "KZ": (48, 68),
        "AM": (40.2, 44.5), "GE": (42, 43.5), "MD": (47, 28.5),
        "UA": (49, 32), "PL": (52, 20), "LT": (55.3, 24), "LV": (56.9, 24.6),
        "EE": (59, 26), "CZ": (49.8, 15.5), "AT": (47.6, 14.1),
        "IT": (42.8, 12.5), "ES": (40.4, -3.7), "CH": (46.8, 8.2),
        "CA": (56, -106), "KR": (36.5, 128), "JP": (36.3, 138.5),
        "IN": (21, 78), "AU": (-25, 134), "BR": (-10, -52), "CN": (35, 105),
        "TW": (23.7, 121), "VN": (16, 106), "TH": (13.7, 100.5),
        "MY": (4, 102), "SG": (1.35, 103.8), "HK": (22.3, 114.2),
        "ID": (-2, 118), "RO": (45.9, 25), "BG": (42.7, 25.4),
        "RS": (44, 20.5), "IL": (31.5, 34.9), "SA": (24, 45),
        "IR": (32.5, 54), "AR": (-34, -64), "MX": (23, -102),
        "PT": (39.5, -8), "GR": (39, 22), "CY": (35, 33),
        "MN": (46.8, 103.8), "PK": (30, 70), "PH": (12, 122),
        "NZ": (-41, 173), "IE": (53.4, -8.2),
        "DK": (56, 10), "BE": (50.6, 4.6), "LU": (49.8, 6.1),
        "HR": (45.5, 16), "IS": (64.9, -19),
    ]
}