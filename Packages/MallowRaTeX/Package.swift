// swift-tools-version: 6.0
import PackageDescription

// This package is the local visionOS compatibility adapter.
// SwiftStreamingMarkdown uses the official RaTeX Swift package directly on
// iOS and macOS.
let package = Package(
    name: "MallowRaTeX",
    platforms: [
        .iOS(.v14),
        .macOS(.v14),
        .visionOS(.v2)
    ],
    products: [
        .library(name: "MallowRaTeX", targets: ["MallowRaTeX"])
    ],
    targets: [
        .target(
            name: "MallowRaTeX",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "MallowRaTeXTests",
            dependencies: ["MallowRaTeX"]
        )
    ]
)
