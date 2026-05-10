// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "DittoMac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "DittoMac", targets: ["DittoMac"])
    ],
    targets: [
        .systemLibrary(
            name: "CSystem",
            path: "Sources/CSystem"
        ),
        .executableTarget(
            name: "DittoMac",
            dependencies: ["CSystem"],
            path: "Sources/DittoMac"
        )
    ]
)
