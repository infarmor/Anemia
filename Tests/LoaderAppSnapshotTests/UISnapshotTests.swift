import AppKit
import Foundation
import SwiftUI
import Testing
import LoaderCore
@testable import LoaderApp

/// Headless renders of the main surfaces (light + dark) for visual review —
/// no window, no screen-recording permission. Opt-in, since it builds a real
/// AppState: run with a destination directory.
///
///     ANEMIA_SNAPSHOT_DIR=/tmp/anemia-shots bash Scripts/test.sh --filter UISnapshot
///
/// AppKit-backed controls (switches, menus, the desktop blur) render as
/// placeholders or not at all under ImageRenderer; layout, type and color do.
@MainActor
struct UISnapshotTests {
    nonisolated static let outDir = ProcessInfo.processInfo.environment["ANEMIA_SNAPSHOT_DIR"]

    @Test(.enabled(if: outDir != nil))
    func renderSurfaces() throws {
        let dir = URL(fileURLWithPath: try #require(Self.outDir))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stateFile = dir.appendingPathComponent("snapshot-state.json")
        try? FileManager.default.removeItem(at: stateFile)

        let state = AppState(persistence: StatePersistence(fileURL: stateFile))
        state.importLink("vless://00000000-0000-4000-8000-000000000000@nl1.example.com:443?security=reality&pbk=Q1x2&sid=ab&type=tcp&flow=xtls-rprx-vision&sni=www.microsoft.com#%F0%9F%87%B3%F0%9F%87%B1%20Amsterdam")
        state.importLink("vless://00000000-0000-4000-8000-000000000001@de1.example.com:443?security=reality&pbk=Q1x2&sid=ab&type=tcp#%F0%9F%87%A9%F0%9F%87%AA%20Frankfurt")
        #if DEBUG
        let variants: [(String, AppState.PreviewScenario)] = [("idle", .idle), ("connected", .connected), ("repair", .networkNeedsRepair)]
        #else
        let variants: [(String, Void)] = []
        #endif

        for (name, scenario) in variants {
            #if DEBUG
            state.applyPreview(scenario)
            #endif
            for dark in [false, true] {
                let suffix = "\(name)-\(dark ? "dark" : "light")"
                try render(RootView().environmentObject(state), size: CGSize(width: 560, height: 600),
                           dark: dark, to: dir.appendingPathComponent("main-\(suffix).png"))
                try render(MenuContentView().environmentObject(state).frame(width: 340),
                           size: CGSize(width: 340, height: 460),
                           dark: dark, to: dir.appendingPathComponent("menu-\(suffix).png"))
            }
        }
        // Settings: grouped Forms are NSScrollView-backed, which ImageRenderer
        // can't draw — render them hosted in an offscreen window instead.
        #if DEBUG
        state.applyPreview(.connected)
        #endif
        for tab in [SettingsTab.general, .protection, .about] {
            for dark in [false, true] {
                try renderHosted(SettingsView(initialTab: tab).environmentObject(state),
                                 size: CGSize(width: 580, height: 700), dark: dark,
                                 to: dir.appendingPathComponent("settings-\(tab)-\(dark ? "dark" : "light").png"))
            }
        }

        // Statistics, the speed test, the leak test and the server list.
        #if DEBUG
        state.usage.showPreview(Self.sampleLedger(server: state.allServers.first))
        state.leakTest.showPreview(LeakTestModel.Report(
            serverID: state.sessionServerID,
            // Documentation addresses only (RFC 5737): a render of this ends
            // up in the README.
            exit: LeakCheck.IPInfo(ip: "203.0.113.42", countryCode: "NL", country: "Netherlands",
                                   city: "Amsterdam", isp: "Example Hosting"),
            direct: LeakCheck.IPInfo(ip: "198.51.100.17", countryCode: "RU", country: "Russia",
                                     city: "Moscow", isp: "Example ISP"),
            dns: [LeakCheck.DNSServer(ip: "203.0.113.53", countryCode: "NL", country: "Netherlands", org: "Cloudflare"),
                  LeakCheck.DNSServer(ip: "203.0.113.54", countryCode: "NL", country: "Netherlands", org: "Cloudflare")]))
        #endif
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            try renderHosted(StatsSheet().environmentObject(state), size: CGSize(width: 540, height: 600),
                             dark: dark, to: dir.appendingPathComponent("stats-\(suffix).png"))
            try renderHosted(StatsSheet(pane: .speed).environmentObject(state), size: CGSize(width: 540, height: 600),
                             dark: dark, to: dir.appendingPathComponent("speed-\(suffix).png"))
            try renderHosted(LeakTestSheet().environmentObject(state), size: CGSize(width: 500, height: 600),
                             dark: dark, to: dir.appendingPathComponent("leaks-\(suffix).png"))
            try renderHosted(ServersSheet().environmentObject(state), size: CGSize(width: 480, height: 560),
                             dark: dark, to: dir.appendingPathComponent("servers-\(suffix).png"))
        }
    }

    /// Two weeks of made-up traffic.
    private static func sampleLedger(server: ProxyServer?) -> TrafficLedger {
        var ledger = TrafficLedger()
        let now = Date()
        for day in 0..<14 {
            let at = now.addingTimeInterval(-Double(day) * 86_400)
            let received = Int64(180_000_000 + (day * 97 % 11) * 60_000_000)
            ledger.record(runStartedAt: at, received: received, sent: received / 12,
                          server: server.map { ($0.id, $0.name) }, at: at)
        }
        return ledger
    }

    private func renderHosted<V: View>(_ view: V, size: CGSize, dark: Bool, to url: URL) throws {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(rootView: view
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.snapshotRendering, true))
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.appearance = appearance
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        // ARC owns the window; the AppKit default would release it again on close.
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try data.write(to: url)
        window.close()
    }

    private func render<V: View>(_ view: V, size: CGSize, dark: Bool, to url: URL) throws {
        let content = view
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(Theme.background)
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.snapshotRendering, true)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        // Theme colors are dynamic NSColors: they resolve against the current
        // drawing appearance, not the SwiftUI environment.
        var image: CGImage?
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            image = renderer.cgImage
        }
        let cg = try #require(image)
        let data = try #require(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
        try data.write(to: url)
    }
}
