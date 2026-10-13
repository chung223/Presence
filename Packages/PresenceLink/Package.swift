// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PresenceLink",
    defaultLocalization: "zh-Hant",
    platforms: [.macOS(.v26), .iOS(.v26), .watchOS(.v26)],
    products: [
        .library(name: "PresenceLink", targets: ["PresenceLink"]),
    ],
    targets: [
        .target(name: "PresenceLink", resources: [.process("Localizable.xcstrings")]),
        .testTarget(name: "PresenceLinkTests", dependencies: ["PresenceLink"]),
    ]
)
