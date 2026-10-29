import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AIGenerationMetadata

/// Rotated JPEG dimensions, Midjourney's trailing Job ID, and InvokeAI 4's model name.
final class ExtractionDefectTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExtractionDefectTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testRotatedJPEGReportsDisplayedDimensions() throws {
        // Stored 40×30 with orientation 6 (rotate 90° clockwise) displays as 30×40.
        let url = try makeJPEG(width: 40, height: 30, orientation: 6)

        let result = MediaMetadataExtractor.extract(from: url)

        XCTAssertEqual(result.width, 30)
        XCTAssertEqual(result.height, 40)
        XCTAssertEqual(result.aspectRatio, "3:4")
    }

    func testUprightJPEGKeepsStoredDimensions() throws {
        let url = try makeJPEG(width: 40, height: 30, orientation: 1)

        let result = MediaMetadataExtractor.extract(from: url)

        XCTAssertEqual(result.width, 40)
        XCTAssertEqual(result.height, 30)
        XCTAssertEqual(result.aspectRatio, "4:3")
    }

    func testMidjourneyJobIDWithoutFlagsStaysOutOfThePrompt() {
        let result = FormatParsers.parseMidjourney(
            "a lighthouse at dusk Job ID: 3f1c2b9e-0000-4000-8000-000000000000", into: ExtractedMediaMetadata()
        )

        XCTAssertEqual(result.prompt, "a lighthouse at dusk")
    }

    func testMidjourneyJobIDAfterFlagsStillParsesTheVersion() {
        let result = FormatParsers.parseMidjourney(
            "a lighthouse --ar 3:2 --v 6.1 Job ID: 3f1c2b9e-0000-4000-8000-000000000000", into: ExtractedMediaMetadata()
        )

        XCTAssertEqual(result.prompt, "a lighthouse")
        XCTAssertEqual(result.model, "Midjourney v6.1")
    }

    func testInvokeAI4ModelNameIsRead() {
        let json = #"{"positive_prompt":"a fox","model":{"key":"abc","hash":"blake3:1","name":"juggernautXL","base":"sdxl","type":"main"}}"#

        let result = FormatParsers.parseInvokeAI(json, into: ExtractedMediaMetadata())

        XCTAssertEqual(result.model, "juggernautXL")
    }

    func testInvokeAI3ModelNameStillWorks() {
        let json = #"{"positive_prompt":"a fox","model":{"model_name":"sd-1.5","base_model":"sd-1"}}"#

        let result = FormatParsers.parseInvokeAI(json, into: ExtractedMediaMetadata())

        XCTAssertEqual(result.model, "sd-1.5")
    }

    private func makeJPEG(width: Int, height: Int, orientation: Int) throws -> URL {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let url = tempDir.appendingPathComponent("rotated-\(orientation).jpg")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }
}
