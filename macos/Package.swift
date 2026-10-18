// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Crumble",
    platforms: [.macOS(.v26)],
    dependencies: [.package(url: "git@github.com:crumble-project/apfelkern.git", branch: "main")],
    targets: [
        .target(name: "BotAvatar"),
        .executableTarget(name: "Crumble", dependencies: ["apfelkern", "BotAvatar"]),
        .executableTarget(name: "AvatarPlayground", dependencies: ["BotAvatar"]),
        .testTarget(name: "CrumbleTests", dependencies: ["Crumble", "apfelkern", "BotAvatar"])
    ]
)
