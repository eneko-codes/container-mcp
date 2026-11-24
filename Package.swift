// swift-tools-version: 6.2
import PackageDescription

// apple/container is pinned exactly: its XPC messages are Codable structs with no version
// negotiation, so the library must match the installed container service release.
// NativeBackend.expectedServiceVersion must change together with this pin.
let package = Package(
    name: "container-mcp",
    platforms: [.macOS("15")],
    products: [
        .executable(name: "container-mcp", targets: ["container-mcp"])
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
        .package(url: "https://github.com/apple/container.git", exact: "1.7.1"),
    ],
    targets: [
        .target(
            name: "ContainerMCPCore",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "ContainerMCPNative",
            dependencies: [
                "ContainerMCPCore",
                .product(name: "ContainerAPIClient", package: "container"),
                .product(name: "ContainerResource", package: "container"),
                .product(name: "ContainerBuild", package: "container"),
                .product(name: "ContainerImagesService", package: "container"),
                .product(name: "ContainerPersistence", package: "container"),
                .product(name: "ContainerPlugin", package: "container"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "container-mcp",
            dependencies: [
                "ContainerMCPCore",
                "ContainerMCPNative",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "container-mcp-probe",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ContainerMCPCoreTests",
            dependencies: ["ContainerMCPCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ContainerMCPIntegrationTests",
            dependencies: ["ContainerMCPCore", "ContainerMCPNative"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
