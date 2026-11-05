// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ChaiMusicCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "ChaiMusicCore", targets: ["ChaiMusicCore"])],
    targets: [
        .target(name: "ChaiMusicCore", path: "ChaiMusic/Core",
                sources: ["Models.swift", "QueueEngine.swift", "LRCParser.swift"]),
        .testTarget(name: "ChaiMusicCoreTests", dependencies: ["ChaiMusicCore"], path: "Tests/ChaiMusicCoreTests")
    ],
    swiftLanguageVersions: [.v5]
)
