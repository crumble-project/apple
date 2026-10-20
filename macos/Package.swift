// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Crumble",
    platforms: [.macOS(.v26)],
    dependencies: [.package(url: "https://github.com/crumble-project/apfelkern.git", revision: "abdcd85b0b4ba8a26ef7eda8cf27c122004812f2")],
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
