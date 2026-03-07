// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "QuickSwitch",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "QuickSwitch",
            path: "src",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
