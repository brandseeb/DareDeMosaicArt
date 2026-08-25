// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ConfessionDefense",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "ConfessionDefense",
            targets: ["ConfessionDefense"]
        ),
    ],
    targets: [
        .target(
            name: "ConfessionDefense",
            path: "Sources"
        ),
    ]
)
