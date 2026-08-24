// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "sillage",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SillageCore", targets: ["SillageCore"])
    ],
    targets: [
        .target(name: "SillageCore"),
        .testTarget(name: "SillageCoreTests", dependencies: ["SillageCore"])
    ]
)
