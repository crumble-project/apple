// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Crumble",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "Crumble"),
        .testTarget(name: "CrumbleTests", dependencies: ["Crumble"])
    ]
)
