// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ClaudeAnchor",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Anchor",
            path: "Sources/Anchor",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
