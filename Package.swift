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
        // Already in the graph through apple/container; declared only so the native adapter can
        // import their types (Platform, IPAddress, Logger, FilePath, the build event loop).
        .package(url: "https://github.com/apple/containerization.git", exact: "0.54.0"),
        .package(url: "https://github.com/apple/swift-log.git", exact: "1.17.2"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.105.2"),
        .package(url: "https://github.com/apple/swift-system.git", exact: "1.9.0"),
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
                .product(name: "TerminalProgress", package: "container"),
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "ContainerizationExtras", package: "containerization"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "SystemPackage", package: "swift-system"),
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
