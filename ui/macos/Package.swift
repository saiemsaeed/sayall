// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SayAll",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "SayAll", targets: ["SayAll"])],
    targets: [
        .executableTarget(name: "SayAll"),
        .testTarget(name: "SayAllTests", dependencies: ["SayAll"]),
    ],
    swiftLanguageModes: [.v5]
)
