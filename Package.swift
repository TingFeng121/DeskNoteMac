// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DeskNote",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "DeskNote",
            path: "Sources/DeskNote",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
