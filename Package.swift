// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "xcode-runner",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", .upToNextMinor(from: "1.6.0")),
    ],
    targets: [
        .executableTarget(
            name: "xcode-runner",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources"
        ),
    ]
)
