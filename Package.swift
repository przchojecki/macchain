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
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
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
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/MacChain"
        ),
        .executableTarget(
            name: "MacChainBenchmark",
            dependencies: [
                "MacChainLib",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
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
