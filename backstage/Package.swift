// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Backstage",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Backstage", path: "Sources/Backstage")
    ]
)
