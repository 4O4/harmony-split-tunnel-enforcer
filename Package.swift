// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HarmonySplitTunnelEnforcer",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "HarmonySplitTunnelEnforcer",
            path: "Sources",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Network"),
            ]
        )
    ]
)
