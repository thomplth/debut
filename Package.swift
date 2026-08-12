// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Debut",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Debut", targets: ["DebutApp"]),
        .executable(name: "DebutE2E", targets: ["DebutE2E"]),
        .executable(name: "DebutPerformanceFixture", targets: ["DebutPerformanceFixture"]),
        .executable(name: "DebutBenchmarks", targets: ["DebutBenchmarks"]),
        .library(name: "DebutCore", targets: ["DebutCore"]),
    ],
    targets: [
        .executableTarget(
            name: "DebutApp",
            dependencies: ["DebutCore"],
            path: "Sources/DebutApp"
        ),
        .target(
            name: "DebutCore",
            dependencies: ["AXPrivate"],
            path: "Sources/DebutCore"
        ),
        .target(
            name: "AXPrivate",
            path: "Sources/AXPrivate",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
            ]
        ),
        .executableTarget(
            name: "DebutE2E",
            dependencies: ["DebutCore"],
            path: "Sources/DebutE2E",
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
            ]
        ),
        .executableTarget(
            name: "DebutPerformanceFixture",
            path: "Sources/DebutPerformanceFixture"
        ),
        .executableTarget(
            name: "DebutBenchmarks",
            dependencies: ["DebutCore"],
            path: "Sources/DebutBenchmarks"
        ),
        .testTarget(
            name: "DebutCoreTests",
            dependencies: ["DebutCore"],
            path: "Tests/DebutCoreTests"
        ),
    ]
)
