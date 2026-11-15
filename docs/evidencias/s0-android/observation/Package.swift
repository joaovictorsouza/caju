// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "obs-android",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "obs-android",
            path: "Sources"
        )
    ]
)
