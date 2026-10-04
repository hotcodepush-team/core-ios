// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HotCodePushProtocol",
    platforms: [.iOS(.v13), .macOS(.v12)],
    products: [
        .library(
            name: "HotCodePushProtocol",
            targets: ["HotCodePushProtocol"])
    ],
    targets: [
        .target(
            name: "HotCodePushProtocol",
            dependencies: ["HotCodePushBspatch"],
            path: "Sources/HotCodePushProtocol",
            resources: [.copy("PrivacyInfo.xcprivacy")]),
        .target(
            name: "HotCodePushBspatch",
            path: "Sources/HotCodePushBspatch",
            linkerSettings: [.linkedLibrary("bz2")]),
        .testTarget(
            name: "HotCodePushProtocolTests",
            dependencies: ["HotCodePushProtocol"],
            path: "Tests/HotCodePushProtocolTests")
    ]
)
