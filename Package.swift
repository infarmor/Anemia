// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Loader",
    platforms: [
        .macOS(.v13)
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
            path: "Sources/LoaderCore"
        ),
        // Shared XPC protocol + small value types used by both the app and the
        // privileged helper so they agree on the wire contract.
        .target(
            name: "LoaderShared",
            path: "Sources/LoaderShared"
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
            ]
        ),
        // The privileged helper tool: creates the utun interface and installs
        // routes as root. Talks to the app over XPC.
        .executableTarget(
            name: "LoaderHelper",
            dependencies: ["LoaderShared"],
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
        )
    ]
)
