// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Paddle",
    platforms: [
        .macOS("27.0")
    ],
    products: [
        .library(name: "PaddleCore", targets: ["PaddleCore"])
    ],
    targets: [
        .target(name: "PaddleCore"),
        .testTarget(
            name: "PaddleCoreTests",
            dependencies: ["PaddleCore"]
        )
    ],
    swiftLanguageModes: [.v6]
)
