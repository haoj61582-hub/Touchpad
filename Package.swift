// swift-tools-version: 5.8

import PackageDescription

let package = Package(
    name: "Controller",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(
            name: "ControllerShared",
            targets: ["ControllerShared"]
        ),
        .executable(
            name: "MacCompanionCLI",
            targets: ["MacCompanionCLI"]
        )
    ],
    targets: [
        .target(
            name: "ControllerShared"
        ),
        .executableTarget(
            name: "MacCompanionCLI",
            dependencies: ["ControllerShared"]
        ),
        .testTarget(
            name: "ControllerSharedTests",
            dependencies: ["ControllerShared"]
        )
    ]
)

