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
    targets: [
        .executableTarget(
            name: "MemoDolmaeng",
            path: "Sources/MemoDolmaeng",
            resources: [
                .copy("Resources/MarkdownEditor"),
                .copy("Resources/MarkdownRenderer")
            ]
        )
    ]
)
