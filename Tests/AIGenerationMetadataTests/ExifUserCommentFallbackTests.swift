import ImageIO
import XCTest
@testable import AIGenerationMetadata

/// The direct UserComment read also runs when ImageIO lists the UserComment but not as text.
final class ExifUserCommentFallbackTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ExifFallback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private static let a1111 = "a cat on a sofa\nNegative prompt: ugly\nSteps: 20, Sampler: Euler a, CFG scale: 7, Seed: 5, Size: 4x4"

    func testPiexifUnicodeCommentParsesAsAutomatic1111() throws {
        let url = try writeJPEG(userComment: Array("UNICODE\0".utf8) + Array(Self.a1111.utf16).flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] })
        let result = MediaMetadataExtractor.extract(from: url)
        XCTAssertEqual(result.sourcePlatform, "Automatic1111")
        XCTAssertEqual(result.prompt, "a cat on a sofa")
        XCTAssertEqual(result.steps, 20)
    }

    func testImageIOReadsThePiexifCommentAsTextSoNoDirectReadIsNeeded() throws {
        let url = try writeJPEG(userComment: Array("UNICODE\0".utf8) + Array(Self.a1111.utf16).flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] })
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let exif = try XCTUnwrap(properties[kCGImagePropertyExifDictionary] as? [CFString: Any])
        XCTAssertEqual(exif[kCGImagePropertyExifUserComment] as? String, Self.a1111)
        var directReads = 0
        _ = MediaMetadataExtractor.extract(from: url) { _ in directReads += 1; return nil }
        XCTAssertEqual(directReads, 0)
    }

    func testZeroFilledCommentBesideOtherEXIFTagsIsFinalWithoutADirectRead() throws {
        let url = try writeJPEG(userComment: [UInt8](repeating: 0, count: 8), withISO: true)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        _ = try XCTUnwrap(properties[kCGImagePropertyExifDictionary] as? [CFString: Any])
        var directReads = 0
        _ = MediaMetadataExtractor.extract(from: url) { _ in directReads += 1; return nil }
        XCTAssertEqual(directReads, 0)
    }

    private func writeJPEG(userComment: [UInt8], withISO: Bool = false) throws -> URL {
        func be16(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
        func be32(_ value: Int) -> [UInt8] { be16(value >> 16) + be16(value & 0xFFFF) }
        func entry(_ tag: Int, _ type: Int, _ count: Int, _ value: [UInt8]) -> [UInt8] { be16(tag) + be16(type) + be32(count) + value }
        let exifOffset = 8 + 2 + 12 + 4
        let commentOffset = exifOffset + 2 + (withISO ? 24 : 12) + 4
        var tiff: [UInt8] = Array("MM".utf8) + be16(42) + be32(8)
        tiff += be16(1) + entry(0x8769, 4, 1, be32(exifOffset)) + be32(0)
        tiff += be16(withISO ? 2 : 1)
        if withISO { tiff += entry(0x8827, 3, 1, be16(100) + [0, 0]) }
        tiff += entry(0x9286, 7, userComment.count, be32(commentOffset)) + be32(0)
        tiff += userComment

        let plain = tempDir.appendingPathComponent("plain.jpg")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(plain as CFURL, "public.jpeg" as CFString, 1, nil))
        let image = try XCTUnwrap(TestImage.cgImage(width: 4, height: 4))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let jpeg = try Data(contentsOf: plain)
        let segment = Array("Exif\0\0".utf8) + tiff
        let marker: [UInt8] = [0xFF, 0xE1] + be16(segment.count + 2)
        let url = tempDir.appendingPathComponent("piexif.jpg")
        try (jpeg.prefix(2) + Data(marker + segment) + jpeg.dropFirst(2)).write(to: url)
        return url
    }
}
