// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "Sunlight", platforms: [.macOS(.v14)], products: [.executable(name: "Sunlight", targets: ["Sunlight"])], targets: [.executableTarget(name: "Sunlight")])
