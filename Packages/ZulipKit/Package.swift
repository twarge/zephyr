// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ZulipKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ZulipAPI", targets: ["ZulipAPI"]),
        .library(name: "ZulipModel", targets: ["ZulipModel"]),
        .library(name: "ZulipContent", targets: ["ZulipContent"]),
        .executable(name: "zulip-harness", targets: ["Harness"]),
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
    ],
    targets: [
        .target(name: "ZulipAPI"),
        .target(name: "ZulipModel", dependencies: ["ZulipAPI"]),
        .target(name: "ZulipContent", dependencies: ["SwiftSoup"]),
        .executableTarget(name: "Harness", dependencies: ["ZulipAPI", "ZulipModel"]),
        .target(name: "ZulipTestSupport", dependencies: ["ZulipAPI"]),
        .testTarget(name: "ZulipAPITests", dependencies: ["ZulipAPI", "ZulipTestSupport"]),
        .testTarget(name: "ZulipModelTests", dependencies: ["ZulipModel", "ZulipTestSupport"]),
        .testTarget(name: "ZulipContentTests", dependencies: ["ZulipContent"]),
    ]
)
