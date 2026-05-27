// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Debut",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Debut", targets: ["DebutApp"]),
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
            path: "Sources/DebutCore"
        ),
        .testTarget(
            name: "DebutCoreTests",
            dependencies: ["DebutCore"],
            path: "Tests/DebutCoreTests"
        ),
    ]
)
