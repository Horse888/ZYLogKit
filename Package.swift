// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ZYLogKit",
    platforms: [
        .iOS(.v12),
        .macOS(.v10_15),
        .tvOS(.v13),
        .watchOS(.v6)
    ],
    products: [
        .library(
            name: "ZYLogKit",
            targets: ["ZYLogKit"]
        )
    ],
    targets: [
        .target(
            name: "ZYLogKit"
        ),
        .testTarget(
            name: "ZYLogKitTests",
            dependencies: ["ZYLogKit"]
        )
    ]
)
