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
    ],
    targets: [
        .target(
            name: "swift-modularity"),
        .testTarget(
            name: "swift-modularityTests",
            dependencies: ["swift-modularity"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
