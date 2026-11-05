// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "apfelkern",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "apfelkern", targets: ["apfelkern"]),
        .library(name: "BotAvatar", targets: ["BotAvatar"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-runtime", exact: "1.13.2"),
        .package(url: "https://github.com/apple/swift-http-types", exact: "1.7.0"),
        .package(url: "https://github.com/cheetahbyte/open-bot-avatar-swift.git", exact: "0.1.0")
    ],
    targets: [
        .target(name: "apfelkern", dependencies: [
            .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
            .product(name: "HTTPTypes", package: "swift-http-types"),
            .product(name: "OpenBotAvatar", package: "open-bot-avatar-swift")
        ]),
        .target(name: "BotAvatar", dependencies: [
            "apfelkern",
            .product(name: "OpenBotAvatar", package: "open-bot-avatar-swift"),
            .product(name: "OpenBotAvatarUI", package: "open-bot-avatar-swift")
        ]),
        .testTarget(name: "apfelkernTests", dependencies: [
            "apfelkern", .product(name: "OpenBotAvatar", package: "open-bot-avatar-swift")
        ]),
        .testTarget(name: "BotAvatarTests", dependencies: [
            "BotAvatar",
            .product(name: "OpenBotAvatar", package: "open-bot-avatar-swift"),
            .product(name: "OpenBotAvatarUI", package: "open-bot-avatar-swift")
        ])
    ]
)
