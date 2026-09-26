// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Murmure",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "MurmureCore"),
        .executableTarget(name: "Murmure", dependencies: ["MurmureCore"]),
        .testTarget(name: "MurmureCoreTests", dependencies: ["MurmureCore"]),
    ],
    swiftLanguageModes: [.v5]
)
