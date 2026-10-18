// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "apfelkern",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "apfelkern", targets: ["apfelkern"]),
        .library(name: "BotAvatar", targets: ["BotAvatar"])
    ],
    targets: [
        .target(name: "apfelkern"),
        .target(name: "BotAvatar", dependencies: ["apfelkern"]),
        .testTarget(name: "apfelkernTests", dependencies: ["apfelkern"]),
        .testTarget(name: "BotAvatarTests", dependencies: ["BotAvatar"])
    ]
)
