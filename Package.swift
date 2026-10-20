// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DpaNative",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "DpaNative",
            path: "Sources/DpaNative",
            swiftSettings: []
        )
    ],
    swiftLanguageVersions: [.v5]
)
