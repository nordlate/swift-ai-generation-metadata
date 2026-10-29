import XCTest
@testable import AIGenerationMetadata

/// `PNGProvenanceMarker`: a tool's own chunk next to A1111-style `parameters` relabels the image.
final class ProvenanceMarkerTests: XCTestCase {
    private var tempDir: URL!
    private static let parameters = "a cat\nSteps: 20, Sampler: Euler a, CFG scale: 7, Seed: 5"
    private static let marker = PNGProvenanceMarker(keyword: "example-tool", platform: "Example Tool")

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ProvenanceMarker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func write(_ chunks: [String: String]) throws -> URL {
        let url = tempDir.appendingPathComponent("\(UUID().uuidString).png")
        try XCTUnwrap(TestImage.png(textChunks: chunks)).write(to: url)
        return url
    }

    func testMarkerRelabelsParametersAndKeepsTheFields() throws {
        let url = try write(["parameters": Self.parameters, "example-tool": "{\"version\": 1}"])

        let result = MediaMetadataExtractor.extract(from: url, provenanceMarkers: [Self.marker])

        XCTAssertEqual(result.sourcePlatform, "Example Tool")
        XCTAssertEqual(result.prompt, "a cat")
        XCTAssertEqual(result.steps, 20)
    }

    func testWithoutTheMarkerRegisteredTheFileIsAutomatic1111() throws {
        let url = try write(["parameters": Self.parameters, "example-tool": "1"])

        XCTAssertEqual(MediaMetadataExtractor.extract(from: url).sourcePlatform, "Automatic1111")
    }

    func testMarkerChunkAloneDoesNotLabelTheFile() throws {
        let url = try write(["example-tool": "1"])

        XCTAssertEqual(MediaMetadataExtractor.extract(from: url, provenanceMarkers: [Self.marker]).sourcePlatform, "")
    }

    func testFirstMarkerPresentWins() throws {
        let url = try write(["parameters": Self.parameters, "b-tool": "1"])
        let markers = [
            PNGProvenanceMarker(keyword: "a-tool", platform: "A"),
            PNGProvenanceMarker(keyword: "b-tool", platform: "B"),
            PNGProvenanceMarker(keyword: "parameters", platform: "never"),
        ]

        XCTAssertEqual(MediaMetadataExtractor.extract(from: url, provenanceMarkers: markers).sourcePlatform, "B")
    }
}
