// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ZulipKit",
    platforms: [.macOS(.v26), .iOS(.v26), .tvOS(.v18), .visionOS(.v26)],
    products: [
        .library(name: "ZulipAPI", targets: ["ZulipAPI"]),
        .library(name: "ZulipModel", targets: ["ZulipModel"]),
        .library(name: "ZulipContent", targets: ["ZulipContent"]),
        .library(name: "ZulipMath", targets: ["ZulipMath"]),
        .executable(name: "zulip-harness", targets: ["Harness"]),
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.14.3"),
        .package(url: "https://github.com/mgriebling/SwiftMath.git", from: "1.7.3"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.12.0"),
    ],
    targets: [
        .target(name: "ZulipAPI"),
        .target(
            name: "ZulipModel",
            dependencies: ["ZulipAPI", "ZulipContent", .product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "ZulipContent", dependencies: ["SwiftSoup"]),
        .target(name: "ZulipMath", dependencies: ["SwiftMath"]),
        .executableTarget(name: "Harness", dependencies: ["ZulipAPI", "ZulipModel"]),
        .target(name: "ZulipTestSupport", dependencies: ["ZulipAPI"]),
        .testTarget(name: "ZulipAPITests", dependencies: ["ZulipAPI", "ZulipTestSupport"]),
        .testTarget(name: "ZulipModelTests", dependencies: ["ZulipModel", "ZulipTestSupport"]),
        .testTarget(name: "ZulipContentTests", dependencies: ["ZulipContent"]),
        .testTarget(name: "ZulipMathTests", dependencies: ["ZulipMath"]),
    ]
)
