// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HotCodePushCore",
    platforms: [.iOS(.v13), .macOS(.v12)],
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
            // The pod's bundle directory: the package's own resource bundle takes the manifest alone.
            exclude: ["HotCodePushCorePrivacy.bundle/Info.plist"],
            resources: [.copy("HotCodePushCorePrivacy.bundle/PrivacyInfo.xcprivacy")]),
        .target(
            name: "HotCodePushBspatch",
            path: "Sources/HotCodePushBspatch",
            linkerSettings: [.linkedLibrary("bz2")]),
        .testTarget(
            name: "HotCodePushCoreTests",
            dependencies: ["HotCodePushCore"],
            path: "Tests/HotCodePushCoreTests")
    ]
)
