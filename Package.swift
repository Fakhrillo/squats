// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Squats",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "SquatsKit"),
        .testTarget(name: "SquatsKitTests", dependencies: ["SquatsKit"]),
    ],
    swiftLanguageModes: [.v5]
)
