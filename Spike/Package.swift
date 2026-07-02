// swift-tools-version: 6.2
// Throwaway spike: validates SpeechAnalyzer/SpeechTranscriber end-to-end (PRD §12 milestone 1).
import PackageDescription

let package = Package(
    name: "internos-spike",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "internos-spike", path: "Sources")
    ]
)
