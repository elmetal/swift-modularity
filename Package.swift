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
    dependencies: [
        // A range of major versions, so that packages using another swift-syntax version (such as
        // macro packages) can still add this one.
        .package(url: "https://github.com/swiftlang/swift-syntax.git",
                 "601.0.0"..<"605.0.0"),
    ],
    targets: [
        .target(
            name: "swift-modularity",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]),
        .testTarget(
            name: "swift-modularityTests",
            dependencies: ["swift-modularity"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
