// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VoidMac",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "VoidMac",
            path: "Sources/VoidMac",
            swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]
        )
    ],
    swiftLanguageVersions: [.v5]
)
