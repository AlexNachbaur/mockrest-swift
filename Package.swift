// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "MockREST",
    // Minimum Apple OS versions only — required for Swift concurrency APIs on Apple targets.
    // This does NOT limit platform support: Linux, Windows, and Android ignore this field
    // and are fully supported (by MockRESTCore; the MockREST transport layer requires SwiftNIO).
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        // Full package: engine + the MockService transport adapter. Most consumers want this.
        .library(name: "MockREST", targets: ["MockREST"]),
        // Portable engine only (no SwiftNIO) — for platforms or hosts that execute in-process.
        .library(name: "MockRESTCore", targets: ["MockRESTCore"]),
    ],
    dependencies: [
        // The MockCore platform: shared value model, state store, generators, seed primitives,
        // diagnostics, and the MockHost/MockService transport.
        .package(url: "https://github.com/AlexNachbaur/mockcore-swift.git", from: "0.1.0"),
        // Test-only: the cross-protocol integration test serves REST + GraphQL on one MockHost.
        .package(url: "https://github.com/AlexNachbaur/mockql-swift.git", from: "0.2.0"),
        // Build-time only: enables `swift package generate-documentation`.
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.0"),
    ],
    targets: [
        .target(
            name: "MockRESTCore",
            dependencies: [
                .product(name: "MockCore", package: "mockcore-swift")
            ]
        ),
        .target(
            name: "MockREST",
            dependencies: [
                "MockRESTCore",
                .product(name: "MockCoreTransport", package: "mockcore-swift"),
            ]
        ),
        .testTarget(name: "MockRESTCoreTests", dependencies: ["MockRESTCore"]),
        .testTarget(
            name: "MockRESTIntegrationTests",
            dependencies: [
                "MockREST",
                .product(name: "MockQL", package: "mockql-swift"),
            ]
        ),
    ]
)
