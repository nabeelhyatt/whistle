// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WhistleCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "WhistleCore",
            targets: ["WhistleCore"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "WhistleCore",
            dependencies: []
        ),
        .testTarget(
            name: "WhistleCoreTests",
            dependencies: ["WhistleCore"]
        )
    ]
)
