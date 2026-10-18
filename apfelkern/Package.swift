// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "apfelkern",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "apfelkern", targets: ["apfelkern"])
    ],
    targets: [
        .target(name: "apfelkern"),
        .testTarget(name: "apfelkernTests", dependencies: ["apfelkern"])
    ]
)
