// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Internos",
    platforms: [.macOS(.v27)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0")
    ],
    targets: [
        .executableTarget(
            name: "Internos",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources",
            // Sparkle.framework is embedded in Contents/Frameworks by make-app.sh;
            // the binary needs the matching rpath to find it inside the bundle.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "InternosTests", dependencies: ["Internos"], path: "Tests")
    ]
)
