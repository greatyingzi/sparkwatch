// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SparkWatch",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SparkWatch", targets: ["SparkWatchApp"]),
        .executable(name: "sparkwatch-probe", targets: ["SparkWatchProbe"]),
        .library(name: "SparkWatchCore", targets: ["SparkWatchCore"]),
    ],
    targets: [
        // Pure logic: data channels, parsing, tunnelling, health rules. No UI, so
        // it stays testable from a terminal and reusable by the probe binary.
        .target(name: "SparkWatchCore"),
        // Headless acceptance probe: runs the same pipeline as the app and
        // reconciles the official dashboard numbers against SSH-read ones.
        .executableTarget(name: "SparkWatchProbe", dependencies: ["SparkWatchCore"]),
        .executableTarget(name: "SparkWatchApp", dependencies: ["SparkWatchCore"]),
        .testTarget(name: "SparkWatchCoreTests", dependencies: ["SparkWatchCore"]),
    ]
)
