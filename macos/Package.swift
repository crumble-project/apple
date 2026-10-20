// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Crumble",
    platforms: [.macOS(.v26)],
    dependencies: [.package(url: "https://github.com/crumble-project/apfelkern.git", revision: "2057310722426aff34a0dd68a444c245c1659125")],
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
