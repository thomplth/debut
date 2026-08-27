// swift-tools-version: 6.2
// SPDX-License-Identifier: GPL-3.0-only

import PackageDescription

let package = Package(
    name: "Debut",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Debut", targets: ["DebutApp"]),
        .executable(name: "DebutSpaceSwitchLab", targets: ["DebutSpaceSwitchLab"]),
        .executable(name: "DebutE2E", targets: ["DebutE2E"]),
        .executable(name: "DebutPerformanceFixture", targets: ["DebutPerformanceFixture"]),
        .executable(name: "DebutBenchmarks", targets: ["DebutBenchmarks"]),
        .executable(name: "DebutDemo", targets: ["DebutDemo"]),
        .library(name: "DebutCore", targets: ["DebutCore"]),
        .library(name: "SpaceSwitchLabCore", targets: ["SpaceSwitchLabCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
    ],
    targets: [
        .executableTarget(
            name: "DebutApp",
            dependencies: [
                "DebutCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/DebutApp",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .target(
            name: "DebutCore",
            dependencies: ["AXPrivate"],
            path: "Sources/DebutCore"
        ),
        .target(
            name: "SpaceSwitchLabCore",
            path: "Sources/SpaceSwitchLabCore"
        ),
        .executableTarget(
            name: "DebutSpaceSwitchLab",
            dependencies: ["SpaceSwitchLabCore"],
            path: "Sources/DebutSpaceSwitchLab"
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
        .target(
            name: "DebutInputDriver",
            path: "Sources/DebutInputDriver"
        ),
        .executableTarget(
            name: "DebutPerformanceFixture",
            dependencies: ["DebutInputDriver"],
            path: "Sources/DebutPerformanceFixture"
        ),
        .executableTarget(
            name: "DebutDemo",
            dependencies: ["DebutCore"],
            path: "Sources/DebutDemo"
        ),
        .executableTarget(
            name: "DebutBenchmarks",
            dependencies: ["DebutCore"],
            path: "Sources/DebutBenchmarks"
        ),
        .testTarget(
            name: "DebutCoreTests",
            dependencies: ["DebutCore", "DebutInputDriver"],
            path: "Tests/DebutCoreTests"
        ),
        .testTarget(
            name: "SpaceSwitchLabTests",
            dependencies: ["SpaceSwitchLabCore"],
            path: "Tests/SpaceSwitchLabTests"
        ),
    ]
)
