// swift-tools-version: 6.2
import PackageDescription

// APFELKERN_LOCAL builds against a sibling checkout; CI and releases use the reviewed pin.
let apfelkern: Package.Dependency =
    Context.environment["APFELKERN_LOCAL"] == nil
    ? .package(
        url: "https://github.com/crumble-project/apfelkern.git", revision: "cc2024820d1251ef45dd2f613d8b8b77f7b0357c")
    : .package(path: "../apfelkern")

let package = Package(
    name: "Crumble",
    platforms: [.macOS(.v26)],
    dependencies: [apfelkern],
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
