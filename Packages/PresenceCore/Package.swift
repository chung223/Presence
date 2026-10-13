// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PresenceCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "PresenceCore", targets: ["PresenceCore"]),
    ],
    targets: [
        .target(name: "PresenceCore"),
        .testTarget(name: "PresenceCoreTests", dependencies: ["PresenceCore"]),
    ]
)
