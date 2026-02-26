// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "MacChain",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "MacChainLib", targets: ["MacChainLib"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "MacChainLib",
            path: "Sources/MacChainLib",
            resources: [
                .copy("Shaders"),
            ],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("Accelerate"),
            ]
        ),
        .executableTarget(
            name: "MacChain",
            dependencies: [
                "MacChainLib",
            ],
            path: "Sources/MacChain"
        ),
        .executableTarget(
            name: "MacChainBenchmark",
            dependencies: [
                "MacChainLib",
            ],
            path: "Sources/MacChainBenchmark"
        ),
        .testTarget(
            name: "MacChainTests",
            dependencies: ["MacChainLib"],
            path: "Tests/MacChainTests"
        ),
    ]
)
