// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Crumble",
    platforms: [.macOS(.v26)],
    dependencies: [.package(url: "git@github.com:crumble-project/apfelkern.git", branch: "main")],
    targets: [
        .executableTarget(
            name: "Crumble",
            dependencies: ["apfelkern", .product(name: "BotAvatar", package: "apfelkern")]),
        .executableTarget(
            name: "AvatarPlayground", dependencies: [.product(name: "BotAvatar", package: "apfelkern")]),
        .testTarget(
            name: "CrumbleTests",
            dependencies: ["Crumble", "apfelkern", .product(name: "BotAvatar", package: "apfelkern")])
    ]
)
