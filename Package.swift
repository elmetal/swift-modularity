// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "swift-modularity",
    platforms: [.macOS(.v13)],
    products: [
        .library(
            name: "swift-modularity",
            targets: ["swift-modularity"]),
        .executable(
            name: "swift-modularity-cli",
            targets: ["swift-modularity-cli"]),
        // `swift package modularity`: runs `swift-modularity-cli package` on this package's targets.
        .plugin(
            name: "ModularityPlugin",
            targets: ["ModularityPlugin"]),
    ],
    dependencies: [
        // A range of major versions, so that packages using another swift-syntax version (such as
        // macro packages) can still add this one for its command plugin.
        .package(url: "https://github.com/swiftlang/swift-syntax.git",
                 "601.0.0"..<"605.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git",
                 from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "swift-modularity",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]),
        .executableTarget(
            name: "swift-modularity-cli",
            dependencies: [
                "swift-modularity",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]),
        .plugin(
            name: "ModularityPlugin",
            capability: .command(
                intent: .custom(
                    verb: "modularity",
                    description: "Measure the dependency structure of the package's targets and of the files in each target"
                )
            ),
            dependencies: ["swift-modularity-cli"]
        ),
        .testTarget(
            name: "swift-modularityTests",
            dependencies: ["swift-modularity"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
