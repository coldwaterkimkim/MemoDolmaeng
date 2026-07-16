// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MemoDolmaeng",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MemoDolmaeng", targets: ["MemoDolmaeng"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/nodes-app/swift-markdown-engine",
            exact: "0.10.0"
        )
    ],
    targets: [
        .executableTarget(
            name: "MemoDolmaeng",
            dependencies: [
                .product(name: "MarkdownEngine", package: "swift-markdown-engine")
            ],
            path: "Sources/MemoDolmaeng"
        ),
        .testTarget(
            name: "MemoDolmaengTests",
            dependencies: [
                "MemoDolmaeng",
                .product(name: "MarkdownEngine", package: "swift-markdown-engine")
            ],
            path: "Tests/MemoDolmaengTests"
        )
    ]
)
