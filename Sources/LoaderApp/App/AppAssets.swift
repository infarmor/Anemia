import AppKit

/// Bundled brand assets. The logo ships as a package resource, so it loads both
/// under `swift run` (via `Bundle.module`) and inside the assembled .app.
enum AppAssets {
    static let logo: NSImage? = {
        if let url = Bundle.module.url(forResource: "AnemiaLogo", withExtension: "png") {
            return NSImage(contentsOf: url)
        }
        return nil
    }()
}
