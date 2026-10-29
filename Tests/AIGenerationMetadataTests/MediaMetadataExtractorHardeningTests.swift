import Compression
import XCTest
@testable import AIGenerationMetadata

/// Hostile and out-of-range inputs that could otherwise trap or drive unbounded allocations:
/// 64-bit ComfyUI seeds and PNG/zlib hardening. A reader that traps on one bad file stops a
/// whole batch, so these are kept separate from the format-coverage tests.
final class MediaMetadataExtractorHardeningTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("HardeningTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Parser Hardening

    func testComfyUISeedAtOrAboveInt64MaxIsPreservedExactly() throws {
        // ComfyUI's KSampler accepts the full unsigned 64-bit seed range; these bridge
        // as unsigned NSNumber and used to reach a trapping Int64(Double) conversion.
        let json = #"{"3":{"class_type":"KSampler","inputs":{"seed":9223372036854775808,"steps":20,"cfg":7.0}}}"#
        let url = try makePNG(named: "comfy_big_seed.png", textChunks: ["prompt": json])

        let result = MediaMetadataExtractor.extract(from: url)

        XCTAssertEqual(result.seed, "9223372036854775808")
        XCTAssertEqual(result.steps, 20)
    }

    func testComfyUISeedAboveDoublePrecisionIsPreservedExactly() throws {
        let json = #"{"3":{"class_type":"KSampler","inputs":{"seed":9007199254740993,"steps":20}}}"#
        let url = try makePNG(named: "comfy_precise_seed.png", textChunks: ["prompt": json])

        let result = MediaMetadataExtractor.extract(from: url)

        XCTAssertEqual(result.seed, "9007199254740993")
    }

    func testComfyUIStepsAboveInt32MaxIsClampedNotTrapped() throws {
        let json = #"{"3":{"class_type":"KSampler","inputs":{"seed":1,"steps":2147483648}}}"#
        let url = try makePNG(named: "comfy_big_steps.png", textChunks: ["prompt": json])

        let result = MediaMetadataExtractor.extract(from: url)

        XCTAssertEqual(result.steps, Int32.max)
        XCTAssertEqual(result.seed, "1")
    }

    func testComfyUICyclicModelGraphDoesNotOverflowTheStack() throws {
        // Two LoraLoader nodes whose `model` inputs reference each other.
        let json = """
        {
            "1": {"class_type": "KSampler", "inputs": {"seed": 1, "steps": 10, "model": ["2", 0]}},
            "2": {"class_type": "LoraLoader", "inputs": {"model": ["3", 0]}},
            "3": {"class_type": "LoraLoader", "inputs": {"model": ["2", 0]}}
        }
        """
        let url = try makePNG(named: "comfy_cycle.png", textChunks: ["prompt": json])

        let result = MediaMetadataExtractor.extract(from: url)

        XCTAssertTrue(result.model.isEmpty)
        XCTAssertEqual(result.steps, 10)
    }

    func testHostileIHDRDimensionsAreRejected() throws {
        // IHDR claiming a width above the PNG spec maximum of 2^31-1.
        var ihdr = Data()
        ihdr.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF]) // width
        ihdr.append(contentsOf: [0x00, 0x00, 0x00, 0x01]) // height
        ihdr.append(contentsOf: [8, 2, 0, 0, 0])
        let url = try makeRawPNG(named: "hostile_ihdr.png", chunks: [("IHDR", ihdr)])

        let result = MediaMetadataExtractor.extract(from: url)

        XCTAssertEqual(result.width, 0)
        XCTAssertEqual(result.height, 0)
        XCTAssertTrue(result.aspectRatio.isEmpty)
    }

    func testOversizedIHDRLengthIsSkippedNotRead() throws {
        // IHDR is fixed at 13 bytes. A larger declared length must be seeked past rather
        // than read into memory, and the chunks after it must still parse.
        var oversizedIHDR = validIHDR()
        oversizedIHDR.append(Data(repeating: 0, count: 7)) // 20 bytes total
        var textBody = Data("parameters".utf8)
        textBody.append(0)
        textBody.append(Data("a cat\nSteps: 12, Sampler: Euler".utf8))
        let url = try makeRawPNG(
            named: "oversized_ihdr.png",
            chunks: [("IHDR", oversizedIHDR), ("tEXt", textBody)]
        )

        let result = MediaMetadataExtractor.extract(from: url)

        XCTAssertEqual(result.width, 0, "A malformed IHDR must not supply dimensions")
        XCTAssertEqual(result.height, 0)
        XCTAssertEqual(result.prompt, "a cat", "Parsing must continue past the skipped chunk")
        XCTAssertEqual(result.steps, 12)
    }

    func testTruncatedTextChunkIsIgnored() throws {
        var png = pngSignature()
        png.append(buildPNGChunk(type: "IHDR", body: validIHDR()))
        // A tEXt chunk whose declared length runs far past the end of the file.
        png.append(contentsOf: [0x00, 0x10, 0x00, 0x00])
        png.append(Data("tEXt".utf8))
        png.append(Data("parameters\u{0}truncated".utf8))
        let url = tempDir.appendingPathComponent("truncated.png")
        try png.write(to: url)

        let result = MediaMetadataExtractor.extract(from: url)

        XCTAssertEqual(result.width, 1)
        XCTAssertTrue(result.prompt.isEmpty)
    }

    func testLargeCompressedTextChunkStillParsesBelowTheCap() throws {
        // ~4 MB of padding compresses to a few KB. It sits under the 32 MB output cap,
        // so it must still decode — the cap exists for zlib bombs, not for big prompts.
        let payload = "Steps: 7, Sampler: Euler, Seed: 3" + String(repeating: " ", count: 4_000_000)
        var body = Data("parameters".utf8)
        body.append(0)  // NUL after keyword
        body.append(0)  // compression method: deflate
        body.append(try zlibCompressed(Data(payload.utf8)))
        let url = try makeRawPNG(named: "ztxt_large.png", chunks: [("IHDR", validIHDR()), ("zTXt", body)])

        let result = MediaMetadataExtractor.extract(from: url)

        XCTAssertEqual(result.steps, 7)
        XCTAssertEqual(result.seed, "3")
    }

    func testEmptyCompressedTextChunkKeepsItsKeyword() throws {
        // A valid zlib stream that decodes to zero bytes is an empty value. Treating it
        // as a decode failure dropped the keyword, so an empty zTXt behaved differently
        // from an equally empty tEXt.
        var compressed = Data("parameters".utf8)
        compressed.append(0)  // NUL after keyword
        compressed.append(0)  // compression method: deflate
        compressed.append(try zlibCompressed(Data()))
        let compressedURL = try makeRawPNG(
            named: "ztxt_empty.png", chunks: [("IHDR", validIHDR()), ("zTXt", compressed)]
        )

        var plain = Data("parameters".utf8)
        plain.append(0)
        let plainURL = try makeRawPNG(
            named: "text_empty.png", chunks: [("IHDR", validIHDR()), ("tEXt", plain)]
        )

        let compressedResult = MediaMetadataExtractor.extract(from: compressedURL)
        let plainResult = MediaMetadataExtractor.extract(from: plainURL)

        XCTAssertEqual(compressedResult.sourcePlatform, plainResult.sourcePlatform)
        XCTAssertTrue(compressedResult.prompt.isEmpty)
    }

    // MARK: - Raw PNG Builders

    private func pngSignature() -> Data {
        Data([137, 80, 78, 71, 13, 10, 26, 10])
    }

    func validIHDR() -> Data {
        var ihdr = Data()
        ihdr.append(contentsOf: [0x00, 0x00, 0x00, 0x01]) // width 1
        ihdr.append(contentsOf: [0x00, 0x00, 0x00, 0x01]) // height 1
        ihdr.append(contentsOf: [8, 2, 0, 0, 0])
        return ihdr
    }

    /// Builds a PNG byte-for-byte so tests can supply chunks an image encoder never emits.
    func makeRawPNG(named name: String, chunks: [(String, Data)]) throws -> URL {
        var png = pngSignature()
        for (type, body) in chunks {
            png.append(buildPNGChunk(type: type, body: body))
        }
        png.append(buildPNGChunk(type: "IEND", body: Data()))
        let url = tempDir.appendingPathComponent(name)
        try png.write(to: url)
        return url
    }

    func zlibCompressed(_ data: Data) throws -> Data {
        let destinationSize = data.count + 1024
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: destinationSize)
        defer { destination.deallocate() }
        let written = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
            return compression_encode_buffer(destination, destinationSize, base, raw.count, nil, COMPRESSION_ZLIB)
        }
        guard written > 0 else { throw TestError.invalidPNG }
        // COMPRESSION_ZLIB emits raw deflate; prepend the 2-byte header the parser strips.
        var result = Data([0x78, 0x9C])
        result.append(destination, count: written)
        return result
    }

    private func makePNG(named name: String, textChunks: [String: String]) throws -> URL {
        var chunks: [(String, Data)] = [("IHDR", validIHDR())]
        for (keyword, text) in textChunks.sorted(by: { $0.key < $1.key }) {
            var body = Data(keyword.utf8)
            body.append(0)
            body.append(Data(text.utf8))
            chunks.append(("tEXt", body))
        }
        return try makeRawPNG(named: name, chunks: chunks)
    }

    private func buildPNGChunk(type: String, body: Data) -> Data {
        var chunk = Data()
        var length = UInt32(body.count).bigEndian
        chunk.append(Data(bytes: &length, count: 4))
        let typeData = Data(type.utf8)
        chunk.append(typeData)
        chunk.append(body)
        var crcInput = typeData
        crcInput.append(body)
        var crc = crc32(crcInput).bigEndian
        chunk.append(Data(bytes: &crc, count: 4))
        return chunk
    }

    private func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xEDB8_8320 : 0)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    enum TestError: Error {
        case invalidPNG
    }
}
