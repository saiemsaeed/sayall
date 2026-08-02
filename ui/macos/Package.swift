// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SayAll",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "SayAllApp", targets: ["SayAll"]),
    ],
    targets: [
        .target(name: "SayAllControl"),
        .executableTarget(name: "SayAll", dependencies: ["SayAllControl"]),
        .testTarget(name: "SayAllTests", dependencies: ["SayAll", "SayAllControl"]),
    ],
    swiftLanguageModes: [.v5]
)
