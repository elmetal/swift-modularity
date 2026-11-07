// swift-tools-version: 6.1
// Evaluation of swift-modularity's file dependency graph against the compiler's index.
// A separate package so that swift-modularity itself does not depend on IndexStoreDB.

import PackageDescription

let package = Package(
    name: "GraphAccuracy",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../.."),
        .package(url: "https://github.com/swiftlang/indexstore-db.git", revision: "swift-6.4.2-RELEASE"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "graph-accuracy",
            dependencies: [
                .product(name: "swift-modularity", package: "swift-modularity"),
                .product(name: "IndexStoreDB", package: "indexstore-db"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]),
    ],
    swiftLanguageModes: [.v6]
)
