// swift-tools-version: 6.2
import PackageDescription

// APFELKERN_LOCAL builds against a sibling checkout; CI and releases use the reviewed pin.
let apfelkern: Package.Dependency =
    Context.environment["APFELKERN_LOCAL"] == nil
    ? .package(
        url: "https://github.com/crumble-project/apfelkern.git", revision: "06eb6dae52930c804e796c93370357f708c576d7")
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
