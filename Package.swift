// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VibeTunnel",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "VibeTunnel",
            targets: ["VibeTunnel"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/realm/SwiftLint.git", from: "0.57.0"),
        .package(url: "https://github.com/nicklockwood/SwiftFormat.git", from: "0.55.0")
    ],
    targets: [
        .target(
            name: "VibeTunnel",
            dependencies: [],
            path: "VibeTunnel"
        ),
        .testTarget(
            name: "VibeTunnelTests",
            dependencies: ["VibeTunnel"],
            path: "VibeTunnelTests"
        )
    ]
)
