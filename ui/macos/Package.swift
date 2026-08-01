// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SayAll",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "SayAllApp", targets: ["SayAll"]),
        .executable(name: "sayall", targets: ["SayAllCLI"]),
    ],
    targets: [
        .target(name: "SayAllControl"),
        .executableTarget(name: "SayAll", dependencies: ["SayAllControl"]),
        .executableTarget(name: "SayAllCLI", dependencies: ["SayAllControl"], path: "CLI"),
        .testTarget(name: "SayAllTests", dependencies: ["SayAll", "SayAllCLI", "SayAllControl"]),
    ],
    swiftLanguageModes: [.v5]
)
