// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Squats",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "SquatsKit"),
        .executableTarget(name: "PoseSpike", dependencies: ["SquatsKit"]),
        .executableTarget(name: "Squats", dependencies: ["SquatsKit"]),
        .testTarget(name: "SquatsKitTests", dependencies: ["SquatsKit"]),
    ],
    swiftLanguageModes: [.v5]
)
