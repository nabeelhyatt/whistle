// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WhistleCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "WhistleCore",
            targets: ["WhistleCore"]
        )
    ],
    dependencies: [
        // Pinned exact versions (TECH-SPEC §2a M6 rule: both are pre-1.0; pin exact,
        // read resolved source in .build/checkouts before writing wrappers).
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
        .package(url: "https://github.com/get-convex/convex-swift.git", exact: "0.8.1")
    ],
    targets: [
        .target(
            name: "WhistleCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "ConvexMobile", package: "convex-swift")
            ]
        ),
        .testTarget(
            name: "WhistleCoreTests",
            dependencies: ["WhistleCore"]
            // No `resources:` entry: TemplatePreviewTests reads the shared
            // fixture file (packages/backend/convex/__tests__/fixtures/
            // template-rendering.json) directly from its source path via
            // #filePath, rather than through Bundle.module — SPM's resource
            // bundling does not dereference a symlink to a file outside the
            // target directory, which a `.copy()` entry here would require.
        )
    ]
)
