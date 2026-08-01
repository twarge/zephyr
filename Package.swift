// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ZulipKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ZulipAPI", targets: ["ZulipAPI"]),
        .library(name: "ZulipModel", targets: ["ZulipModel"]),
        .executable(name: "zulip-harness", targets: ["Harness"]),
    ],
    targets: [
        .target(name: "ZulipAPI"),
        .target(name: "ZulipModel", dependencies: ["ZulipAPI"]),
        .executableTarget(name: "Harness", dependencies: ["ZulipAPI", "ZulipModel"]),
        .target(name: "ZulipTestSupport", dependencies: ["ZulipAPI"]),
        .testTarget(name: "ZulipAPITests", dependencies: ["ZulipAPI", "ZulipTestSupport"]),
        .testTarget(name: "ZulipModelTests", dependencies: ["ZulipModel", "ZulipTestSupport"]),
    ]
)
