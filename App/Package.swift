// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Internos",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "Internos", path: "Sources")
    ]
)
