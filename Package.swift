// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "sillage",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SillageCore", targets: ["SillageCore"]),
        .library(name: "SillageRender", targets: ["SillageRender"]),
        .executable(name: "sillage-render", targets: ["sillage-render"]),
    ],
    targets: [
        .target(name: "SillageCore"),
        .target(name: "SillageRender", dependencies: ["SillageCore"]),
        .executableTarget(name: "sillage-render", dependencies: ["SillageCore", "SillageRender"]),
        .testTarget(name: "SillageCoreTests", dependencies: ["SillageCore"]),
    ]
)
