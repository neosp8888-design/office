// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "OfficeGame",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "OfficeCore", targets: ["OfficeCore"]),
        .executable(name: "OfficeGame", targets: ["OfficeGame"])
    ],
    targets: [
        .target(
            name: "OfficeCore",
            resources: [
                .copy("Resources/office-theme-modern-day-v4.png"),
                .copy("Resources/office-theme-modern-night-v4.png"),
                .copy("Resources/office-theme-wood-day-v4.png"),
                .copy("Resources/office-theme-wood-night-v4.png"),
                .copy("Resources/office-background-3d-v4.png"),
                .copy("Resources/office-3d-motion-v1"),
                .copy("Resources/characters.json")
            ],
            linkerSettings: [
                .linkedFramework("AppKit")
            ]
        ),
        .executableTarget(
            name: "OfficeGame",
            dependencies: ["OfficeCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SpriteKit")
            ]
        ),
        .testTarget(
            name: "OfficeCoreTests",
            dependencies: ["OfficeCore"]
        )
    ]
)
