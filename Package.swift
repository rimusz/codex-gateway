// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodexGateway",
    platforms: [.macOS("26.0")],
    products: [
        .executable(
            name: "CodexGateway",
            targets: ["CodexGateway"]
        )
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "CodexGateway",
            path: "CodexGateway",
            exclude: [
                // Packaged via scripts/bundle-cursor-bridge.sh (npm ci + copy into .app)
                "Resources/CursorBridge",
            ],
            resources: [
                .process("Resources/Assets.xcassets")
            ]
        ),
        .testTarget(
            name: "CodexGatewayTests",
            dependencies: ["CodexGateway"]
        )
    ]
)
