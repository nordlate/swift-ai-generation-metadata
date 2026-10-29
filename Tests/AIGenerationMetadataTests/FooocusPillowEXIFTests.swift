import ImageIO
import XCTest
@testable import AIGenerationMetadata

/// Fooocus JPEG and WebP files, written the way Fooocus writes them.
///
/// The fixtures were made with Pillow 12.3 using Fooocus's `get_exif` verbatim
/// (lllyasviel/Fooocus main, modules/meta_parser.py, checked 2026-09-29) and the save calls in
/// modules/private_logger.py:
///
///     exif = Image.Exif()
///     exif[0x9286] = metadata                 # UserComment: the parameters JSON
///     exif[0x0131] = 'Fooocus v' + version    # Software
///     exif[0x927C] = metadata_scheme          # MakerNote: "fooocus"
///     image.save(path, quality=95, optimize=True, progressive=True, exif=exif)   # JPEG
///     image.save(path, quality=95, lossless=False, exif=exif)                   # WebP
///
/// with an 8×8 image and the parameters JSON Fooocus's `to_string` produces (sorted keys).
/// Pillow puts all three tags in IFD0 as ASCII values, so ImageIO exposes no EXIF dictionary
/// for them at all; the fixtures written by ImageIO elsewhere in the suite do not show this.
final class FooocusPillowEXIFTests: XCTestCase {

    static let jpeg = "/9j/4AAQSkZJRgABAQAAAQABAAD/4QH0RXhpZgAATU0AKgAAAAgAAwExAAIAAAAPAAAAMpJ8AAIAAAAIAAAAQpKGAAIAAAGhAAAASgAAAABGb29vY3VzIHYyLjUuNQAAZm9vb2N1cwB7ImJhc2VfbW9kZWwiOiAianVnZ2VybmF1dFhMX3Y4UnVuZGlmZnVzaW9uLnNhZmV0ZW5zb3JzIiwgImZ1bGxfbmVnYXRpdmVfcHJvbXB0IjogWyJ1Z2x5LCBibHVycnkiXSwgImZ1bGxfcHJvbXB0IjogWyJhIGNhdCBvbiBhIHNvZmEsIGNpbmVtYXRpYyJdLCAiZ3VpZGFuY2Vfc2NhbGUiOiA0LjAsICJtZXRhZGF0YV9zY2hlbWUiOiAiZm9vb2N1cyIsICJuZWdhdGl2ZV9wcm9tcHQiOiAidWdseSwgYmx1cnJ5IiwgInByb21wdCI6ICJhIGNhdCBvbiBhIHNvZmEiLCAicmVzb2x1dGlvbiI6ICIoMTE1MiwgODk2KSIsICJzYW1wbGVyIjogImRwbXBwXzJtX3NkZV9ncHUiLCAic2NoZWR1bGVyIjogImthcnJhcyIsICJzZWVkIjogIjg3NjEyNDExOTAzMjg0MTciLCAic3RlcHMiOiAzMCwgInZlcnNpb24iOiAiRm9vb2N1cyB2Mi41LjUifQAA/9sAQwACAQEBAQECAQEBAgICAgIEAwICAgIFBAQDBAYFBgYGBQYGBgcJCAYHCQcGBggLCAkKCgoKCgYICwwLCgwJCgoK/9sAQwECAgICAgIFAwMFCgcGBwoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoK/8IAEQgACAAIAwEiAAIRAQMRAf/EABUAAQEAAAAAAAAAAAAAAAAAAAAH/8QAFQEBAQAAAAAAAAAAAAAAAAAABgf/2gAMAwEAAhADEAAAAZ2Ad8//xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oACAEBAAEFAn//xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oACAEDAQE/AX//xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oACAECAQE/AX//xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oACAEBAAY/An//xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oACAEBAAE/IX//2gAMAwEAAgADAAAAEAP/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oACAEDAQE/EH//xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oACAECAQE/EH//xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oACAEBAAE/EH//2Q=="
    static let webp = "UklGRkQCAABXRUJQVlA4WAoAAAAIAAAABwAABwAAVlA4IDIAAAAQAgCdASoIAAgAAIAIJaACdLoB+AH6AAPIAP76eV//hx9RhQf+HKf/jJEe7Xn/8X0AAEVYSUbsAQAATU0AKgAAAAgAAwExAAIAAAAPAAAAMpJ8AAIAAAAIAAAAQpKGAAIAAAGhAAAASgAAAABGb29vY3VzIHYyLjUuNQAAZm9vb2N1cwB7ImJhc2VfbW9kZWwiOiAianVnZ2VybmF1dFhMX3Y4UnVuZGlmZnVzaW9uLnNhZmV0ZW5zb3JzIiwgImZ1bGxfbmVnYXRpdmVfcHJvbXB0IjogWyJ1Z2x5LCBibHVycnkiXSwgImZ1bGxfcHJvbXB0IjogWyJhIGNhdCBvbiBhIHNvZmEsIGNpbmVtYXRpYyJdLCAiZ3VpZGFuY2Vfc2NhbGUiOiA0LjAsICJtZXRhZGF0YV9zY2hlbWUiOiAiZm9vb2N1cyIsICJuZWdhdGl2ZV9wcm9tcHQiOiAidWdseSwgYmx1cnJ5IiwgInByb21wdCI6ICJhIGNhdCBvbiBhIHNvZmEiLCAicmVzb2x1dGlvbiI6ICIoMTE1MiwgODk2KSIsICJzYW1wbGVyIjogImRwbXBwXzJtX3NkZV9ncHUiLCAic2NoZWR1bGVyIjogImthcnJhcyIsICJzZWVkIjogIjg3NjEyNDExOTAzMjg0MTciLCAic3RlcHMiOiAzMCwgInZlcnNpb24iOiAiRm9vb2N1cyB2Mi41LjUifQAA"

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("FooocusPillowEXIF-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func write(_ base64: String, as name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try XCTUnwrap(Data(base64Encoded: base64)).write(to: url)
        return url
    }

    private func assertFooocus(_ url: URL, file: StaticString = #filePath, line: UInt = #line) {
        let result = MediaMetadataExtractor.extract(from: url)
        XCTAssertEqual(result.sourcePlatform, "Fooocus", file: file, line: line)
        XCTAssertEqual(result.prompt, "a cat on a sofa", file: file, line: line)
        XCTAssertEqual(result.negativePrompt, "ugly, blurry", file: file, line: line)
        XCTAssertEqual(result.model, "juggernautXL_v8Rundiffusion.safetensors", file: file, line: line)
        XCTAssertEqual(result.steps, 30, file: file, line: line)
        XCTAssertEqual(result.guidanceScale, 4.0, file: file, line: line)
        XCTAssertEqual(result.seed, "8761241190328417", file: file, line: line)
        XCTAssertEqual(result.width, 8, file: file, line: line)
    }

    func testImageIOExposesNoEXIFForPillowsLayout() throws {
        // Documents why the fallback exists; if a future macOS reads IFD0 UserComment, the
        // fallback simply stops being needed.
        for (data, name) in [(Self.jpeg, "probe.jpg"), (Self.webp, "probe.webp")] {
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(try write(data, as: name) as CFURL, nil))
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let exif = props?[kCGImagePropertyExifDictionary] as? [CFString: Any]
            XCTAssertNil(exif, name)
        }
    }

    /// A camera-style JPEG has an EXIF dictionary without a UserComment: ImageIO's answer is
    /// final, so the file is not opened a second time to look for one.
    func testJPEGWithEXIFButNoCommentSkipsTheDirectRead() throws {
        let url = tempDir.appendingPathComponent("camera.jpg")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        let image = try XCTUnwrap(TestImage.cgImage(width: 4, height: 4))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyExifDictionary: [kCGImagePropertyExifISOSpeedRatings: [100]]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        var directReads = 0

        let result = MediaMetadataExtractor.extract(from: url) { _ in directReads += 1; return nil }
        XCTAssertEqual(directReads, 0)
        XCTAssertEqual(result.width, 4)

        _ = MediaMetadataExtractor.extract(from: try write(Self.jpeg, as: "pillow.jpg")) { _ in directReads += 1; return nil }
        XCTAssertEqual(directReads, 1, "a file without an EXIF dictionary still gets the direct read")
    }

    /// Known gap: a Fooocus file another tool tagged later (exiftool, say) has an EXIF sub-IFD,
    /// so ImageIO reports an EXIF dictionary, while the comment stays in IFD0, which ImageIO
    /// shows nothing of (not even `Software`). Nothing cheap tells the file from a camera JPEG,
    /// so it is not read, rather than opening every camera JPEG a second time. Built here: IFD0
    /// holds Software and UserComment (ASCII) and points at an EXIF IFD with an ISO value.
    func testFooocusFileWithEXIFSubIFDIsNotReadByTheDirectFallback() throws {
        let json = #"{"base_model": "m.safetensors", "prompt": "a cat", "steps": 7, "metadata_scheme": "fooocus"}"#
        let url = try writeJPEG(software: "Fooocus v2.5.5", ifd0UserComment: json, name: "retagged.jpg")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertNotNil(properties[kCGImagePropertyExifDictionary])
        // macOS 15's ImageIO still shows IFD0 as a TIFF dictionary; the gap is in later versions.
        try XCTSkipIf(properties[kCGImagePropertyTIFFDictionary] != nil, "this ImageIO version shows IFD0")
        XCTAssertEqual(ExifUserCommentReader.userComment(from: url), json, "the comment is there for a direct read")

        var directReads = 0
        let result = MediaMetadataExtractor.extract(from: url) { _ in directReads += 1; return nil }
        XCTAssertEqual(directReads, 0)
        XCTAssertEqual(result.sourcePlatform, "")
    }

    private func writeJPEG(software: String, ifd0UserComment comment: String, name: String) throws -> URL {
        func be16(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
        func be32(_ value: Int) -> [UInt8] { be16(value >> 16) + be16(value & 0xFFFF) }
        func entry(_ tag: Int, _ type: Int, _ count: Int, _ value: [UInt8]) -> [UInt8] { be16(tag) + be16(type) + be32(count) + value }
        let softwareBytes = Array(software.utf8) + [0]
        let commentBytes = Array(comment.utf8) + [0]
        let ifd0Size = 2 + 3 * 12 + 4
        let softwareOffset = 8 + ifd0Size
        let exifOffset = softwareOffset + softwareBytes.count + softwareBytes.count % 2
        let commentOffset = exifOffset + 2 + 12 + 4
        var tiff: [UInt8] = Array("MM".utf8) + be16(42) + be32(8)
        tiff += be16(3)
        tiff += entry(0x0131, 2, softwareBytes.count, be32(softwareOffset))
        tiff += entry(0x8769, 4, 1, be32(exifOffset))
        tiff += entry(0x9286, 2, commentBytes.count, be32(commentOffset))
        tiff += be32(0)
        tiff += softwareBytes + [UInt8](repeating: 0, count: softwareBytes.count % 2)
        tiff += be16(1) + entry(0x8827, 3, 1, be16(100) + [0, 0]) + be32(0)
        tiff += commentBytes

        let plain = tempDir.appendingPathComponent("plain-\(name)")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(plain as CFURL, "public.jpeg" as CFString, 1, nil))
        let image = try XCTUnwrap(TestImage.cgImage(width: 4, height: 4))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let jpeg = try Data(contentsOf: plain)
        let segment = Array("Exif\0\0".utf8) + tiff
        let marker: [UInt8] = [0xFF, 0xE1] + be16(segment.count + 2)
        let url = tempDir.appendingPathComponent(name)
        try (jpeg.prefix(2) + Data(marker + segment) + jpeg.dropFirst(2)).write(to: url)
        return url
    }

    func testFooocusJPEGIsParsed() throws {
        assertFooocus(try write(Self.jpeg, as: "fooocus.jpg"))
    }

    func testFooocusWebPIsParsed() throws {
        assertFooocus(try write(Self.webp, as: "fooocus.webp"))
    }

    func testReaderFindsIFD0AndStandardUserComments() throws {
        let pillow = try XCTUnwrap(ExifUserCommentReader.userComment(from: try write(Self.jpeg, as: "a.jpg")))
        XCTAssertTrue(pillow.hasPrefix("{\"base_model\""), "IFD0 ASCII value, as Pillow writes it")

        // The standard location (EXIF sub-IFD, UNDEFINED with a charset prefix), as ImageIO writes it.
        let url = tempDir.appendingPathComponent("standard.jpg")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        let image = try XCTUnwrap(TestImage.cgImage(width: 4, height: 4))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "Steps: 20"]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertEqual(ExifUserCommentReader.userComment(from: url), "Steps: 20")
    }

    func testReaderRejectsDamagedFilesWithoutCrashing() throws {
        let full = try XCTUnwrap(Data(base64Encoded: Self.jpeg))
        for length in [0, 2, 4, 20, 40, 60, 120, 300, full.count - 1] {
            let url = tempDir.appendingPathComponent("cut-\(length).jpg")
            try full.prefix(length).write(to: url)
            _ = ExifUserCommentReader.userComment(from: url)  // must return, not trap
        }
        var corrupted = full
        for offset in stride(from: 30, to: 200, by: 7) { corrupted[offset] = 0xFF }
        let url = tempDir.appendingPathComponent("corrupt.jpg")
        try corrupted.write(to: url)
        _ = ExifUserCommentReader.userComment(from: url)
        let webp = try XCTUnwrap(Data(base64Encoded: Self.webp))
        let cutWebP = tempDir.appendingPathComponent("cut.webp")
        try webp.prefix(40).write(to: cutWebP)
        XCTAssertNil(ExifUserCommentReader.userComment(from: cutWebP))
    }

    func testOrdinaryCommentsAreStillNotPrompts() throws {
        let url = tempDir.appendingPathComponent("holiday.jpg")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        let image = try XCTUnwrap(TestImage.cgImage(width: 4, height: 4))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "Family holiday"]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let result = MediaMetadataExtractor.extract(from: url)
        XCTAssertEqual(result.sourcePlatform, "")
        XCTAssertEqual(result.prompt, "")
    }
}
