// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LyricsCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "LyricsCore", targets: ["LyricsCore"]),
    ],
    targets: [
        .target(name: "LyricsCore"),
        .testTarget(name: "LyricsCoreTests", dependencies: ["LyricsCore"]),
    ]
)
