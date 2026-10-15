// swift-tools-version: 6.0
import PackageDescription

// Mac-side components: shared store, receiver service, build integration CLI and
// the MCP server. The helper app (Mac/App) links ScreenBridgeMacCore.
let package = Package(
    name: "ScreenBridgeMac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ScreenBridgeMacCore", targets: ["ScreenBridgeMacCore"]),
        .executable(name: "screenbridge", targets: ["screenbridge"]),
        .executable(name: "screenbridge-mcp", targets: ["screenbridge-mcp"]),
    ],
    dependencies: [
        .package(name: "ScreenBridge", path: ".."),
    ],
    targets: [
        .target(
            name: "ScreenBridgeMacCore",
            dependencies: [
                .product(name: "ScreenBridgeProtocol", package: "ScreenBridge"),
                .product(name: "ScreenBridgeTransport", package: "ScreenBridge"),
            ]
        ),
        .executableTarget(name: "screenbridge", dependencies: ["ScreenBridgeMacCore"]),
        .executableTarget(name: "screenbridge-mcp", dependencies: ["ScreenBridgeMacCore"]),
        .testTarget(name: "ScreenBridgeMacCoreTests", dependencies: ["ScreenBridgeMacCore"]),
    ]
)
