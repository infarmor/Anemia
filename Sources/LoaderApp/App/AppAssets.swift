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

    /// Menu-bar variant pre-rendered at a small intrinsic size. The source PNG
    /// is ~400pt, and `MenuBarExtra` labels can render a large `NSImage` at its
    /// native point size even when a SwiftUI `.frame` modifier asks for less —
    /// so the fix has to be in the image itself, not the view. Renders the logo
    /// aspect-fit into an 18pt canvas backed by a 36px (2x) bitmap.
    static let menuBarIcon: NSImage? = {
        guard let logo else { return nil }
        let pointSize: CGFloat = 18
        let pixels = 36 // 18pt @2x
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: pixels,
                                         pixelsHigh: pixels,
                                         bitsPerSample: 8,
                                         samplesPerPixel: 4,
                                         hasAlpha: true,
                                         isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0,
                                         bitsPerPixel: 0) else { return nil }
        let src = logo.size
        guard src.width > 0, src.height > 0 else { return nil }
        let k = min(CGFloat(pixels) / src.width, CGFloat(pixels) / src.height)
        let draw = NSSize(width: src.width * k, height: src.height * k)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        logo.draw(in: NSRect(x: (CGFloat(pixels) - draw.width) / 2,
                             y: (CGFloat(pixels) - draw.height) / 2,
                             width: draw.width,
                             height: draw.height),
                  from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize))
        image.addRepresentation(rep)
        // Template image: the menu bar inverts it to stay legible in both light
        // and dark menu bars (and alongside the system items). A non-template
        // color icon renders as-is and vanishes against a same-tone bar.
        image.isTemplate = true
        return image
    }()
}
