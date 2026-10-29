// swift-tools-version: 6.0
// AIGenerationMetadata: reads the prompt, model and settings that AI image and video tools embed in their files.
import PackageDescription

let package = Package(
    name: "swift-ai-generation-metadata",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "AIGenerationMetadata", targets: ["AIGenerationMetadata"]),
    ],
    targets: [
        .target(name: "AIGenerationMetadata"),
        .testTarget(name: "AIGenerationMetadataTests", dependencies: ["AIGenerationMetadata"]),
    ],
    swiftLanguageModes: [.v6]
)
