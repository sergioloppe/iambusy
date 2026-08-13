// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Busy",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Busy", path: "Sources/Busy")
    ]
)
