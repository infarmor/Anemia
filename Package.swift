// swift-tools-version:6.0
import PackageDescription

// Apple Silicon release optimizations. Cross-module optimization lets the
// optimizer specialize across LoaderApp ↔ LoaderCore boundaries (the config
// builders and parsers get inlined into their call sites instead of paying
// a module-boundary call), and -dead_strip removes the unreachable code the
// WMO pass marks. Dev (debug) builds are untouched — fast incremental
// compiles matter more there than the last few percent of runtime.
let releaseSwift: [SwiftSetting] = [
    .unsafeFlags(["-cross-module-optimization"], .when(configuration: .release))
]
let releaseLinker: [LinkerSetting] = [
    .unsafeFlags(["-Xlinker", "-dead_strip"], .when(configuration: .release))
]

let package = Package(
    name: "Loader",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "LoaderCore", targets: ["LoaderCore"]),
        .executable(name: "LoaderApp", targets: ["LoaderApp"]),
        .executable(name: "LoaderHelper", targets: ["LoaderHelper"]),
        .executable(name: "LoaderTool", targets: ["LoaderTool"])
    ],
    targets: [
        // Pure, dependency-free logic: parsing share links / subscriptions and
        // building Xray configuration. Fully unit-testable, no macOS UI or root.
        .target(
            name: "LoaderCore",
            path: "Sources/LoaderCore",
            swiftSettings: releaseSwift
        ),
        // Shared XPC protocol, the helper's LaunchDaemon definition, and the
        // network-safety policy (what counts as a leftover pin) used by both
        // the app and the privileged helper so they agree on the contract.
        .target(
            name: "LoaderShared",
            dependencies: ["LoaderCore"],
            path: "Sources/LoaderShared",
            swiftSettings: releaseSwift
        ),
        // The menu-bar SwiftUI application (the user-facing client).
        .executableTarget(
            name: "LoaderApp",
            dependencies: ["LoaderCore", "LoaderShared"],
            path: "Sources/LoaderApp",
            resources: [
                .process("Resources/AnemiaLogo.png"),
                .copy("Resources/AnemiaAppIcon.icns"),
                .copy("Resources/kxc.mlmodelc"),   // pre-compiled; copy verbatim
            ],
            swiftSettings: releaseSwift,
            linkerSettings: releaseLinker
        ),
        // The privileged helper tool: creates the utun interface and installs
        // routes as root. Talks to the app over XPC.
        .executableTarget(
            name: "LoaderHelper",
            dependencies: ["LoaderShared", "LoaderCore"],
            path: "Sources/LoaderHelper"
        ),
        // Small CLI for scripting/CI: emit or validate an Xray config from a
        // share link without launching the GUI.
        .executableTarget(
            name: "LoaderTool",
            dependencies: ["LoaderCore"],
            path: "Sources/LoaderTool"
        ),
        .testTarget(
            name: "LoaderCoreTests",
            dependencies: ["LoaderCore"],
            path: "Tests/LoaderCoreTests"
        ),
        // Parser regression tests for the helper's network plumbing: the
        // gateway parsing that decides whether the tunnel can come up at all.
        .testTarget(
            name: "LoaderHelperTests",
            dependencies: ["LoaderHelper", "LoaderShared"],
            path: "Tests/LoaderHelperTests"
        ),
        // Headless UI renders for visual review (opt-in: ANEMIA_SNAPSHOT_DIR).
        .testTarget(
            name: "LoaderAppSnapshotTests",
            dependencies: ["LoaderApp", "LoaderCore"],
            path: "Tests/LoaderAppSnapshotTests"
        )
    ]
)
