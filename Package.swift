// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HotCodePushCore",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(
            name: "HotCodePushCore",
            targets: ["HotCodePushCore"])
    ],
    targets: [
        .target(
            name: "HotCodePushCore",
            dependencies: ["HotCodePushBspatch"],
            path: "Sources/HotCodePushCore",
            resources: [.copy("PrivacyInfo.xcprivacy")]),
        .target(
            name: "HotCodePushBspatch",
            path: "Sources/HotCodePushBspatch",
            linkerSettings: [.linkedLibrary("bz2")]),
        .testTarget(
            name: "HotCodePushCoreTests",
            dependencies: ["HotCodePushCore"],
            path: "Tests/HotCodePushCoreTests")
    ],
    swiftLanguageModes: [.v5]
)
