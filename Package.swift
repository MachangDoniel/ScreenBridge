// swift-tools-version: 6.0
import PackageDescription

// Host apps depend only on the `ScreenBridge` product. The Mac receiver, CLI and
// MCP server live in `Mac/Package.swift` so iOS consumers never resolve them.
// Release builds of an iOS app compile the shared models and transport to empty
// modules, so no ScreenBridge code or metadata reaches a distribution binary.
// (macOS Release builds keep them: the Mac helper needs them.)
let stripInAppReleaseBuilds: [SwiftSetting] = [
    .define("SCREENBRIDGE_STRIPPED", .when(platforms: [.iOS, .tvOS, .visionOS, .macCatalyst], configuration: .release)),
]

let package = Package(
    name: "ScreenBridge",
    platforms: [.iOS(.v16), .macOS(.v14)],
    products: [
        .library(name: "ScreenBridge", targets: ["ScreenBridge"]),
        .library(name: "ScreenBridgeProtocol", targets: ["ScreenBridgeProtocol"]),
        .library(name: "ScreenBridgeTransport", targets: ["ScreenBridgeTransport"]),
    ],
    targets: [
        .target(name: "ScreenBridgeProtocol", swiftSettings: stripInAppReleaseBuilds),
        .target(name: "ScreenBridgeTransport", dependencies: ["ScreenBridgeProtocol"], swiftSettings: stripInAppReleaseBuilds),
        .target(
            name: "ScreenBridge",
            dependencies: ["ScreenBridgeProtocol", "ScreenBridgeTransport"],
            swiftSettings: [
                // Inspector, capture, networking and registration code compiles only in
                // debug builds. Release builds get no-op API stubs (see Docs/Security.md).
                .define("SCREENBRIDGE_ENABLED", .when(configuration: .debug)),
            ]
        ),
        .testTarget(name: "ScreenBridgeProtocolTests", dependencies: ["ScreenBridgeProtocol"]),
        .testTarget(name: "ScreenBridgeTransportTests", dependencies: ["ScreenBridgeTransport"]),
        .testTarget(
            name: "ScreenBridgeTests",
            dependencies: ["ScreenBridge"],
            swiftSettings: [.define("SCREENBRIDGE_ENABLED", .when(configuration: .debug))]
        ),
    ]
)
