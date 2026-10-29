import XCTest
@testable import AIGenerationMetadata

/// The file's content, not its extension, picks the parser, and a platform is labelled
/// only when its data is recognised.
final class ImageSignatureAndPlatformTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SignatureTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testJPEGNamedPNGKeepsItsDimensions() throws {
        let url = try write(bitmap(.jpeg, width: 8, height: 4), as: "photo.png")

        let result = MediaMetadataExtractor.extract(from: url)

        XCTAssertEqual(result.width, 8)
        XCTAssertEqual(result.height, 4)
        XCTAssertEqual(result.aspectRatio, "2:1")
        XCTAssertEqual(result.sourcePlatform, "")
    }

    func testPNGNamedJPGReadsItsTextChunks() throws {
        let png = try injecting(["parameters": "a cat\nSteps: 12, Sampler: Euler, CFG scale: 5, Seed: 7"],
                                into: bitmap(.png, width: 6, height: 3))
        let url = try write(png, as: "render.jpg")

        let result = MediaMetadataExtractor.extract(from: url)

        XCTAssertEqual(result.width, 6)
        XCTAssertEqual(result.height, 3)
        XCTAssertEqual(result.prompt, "a cat")
        XCTAssertEqual(result.steps, 12)
        XCTAssertEqual(result.sourcePlatform, "Automatic1111")
    }

    func testPlainTextPromptChunkStaysUnclassified() throws {
        let png = try injecting(["prompt": "just some words, not a graph"], into: bitmap(.png, width: 4, height: 4))
        let url = try write(png, as: "easy.png")

        let result = MediaMetadataExtractor.extract(from: url)

        XCTAssertEqual(result.width, 4)
        XCTAssertEqual(result.sourcePlatform, "")
        XCTAssertEqual(result.prompt, "")
    }

    func testTruncatedInvokeAIChunkStaysUnclassified() throws {
        let png = try injecting(["invokeai_metadata": "{\"positive_prompt\": \"a fo"], into: bitmap(.png, width: 4, height: 4))
        let url = try write(png, as: "invoke.png")

        XCTAssertEqual(MediaMetadataExtractor.extract(from: url).sourcePlatform, "")
    }

    func testRecognisedGraphIsStillComfyUI() throws {
        let graph = #"{"1": {"class_type": "CLIPTextEncode", "inputs": {"text": "a fox"}}}"#
        let png = try injecting(["prompt": graph], into: bitmap(.png, width: 4, height: 4))
        let url = try write(png, as: "comfy.png")

        let result = MediaMetadataExtractor.extract(from: url)

        XCTAssertEqual(result.sourcePlatform, "ComfyUI")
        XCTAssertEqual(result.prompt, "a fox")
    }

    func testWorkflowOnlyPNGIsComfyUI() throws {
        let workflow = #"{"nodes": [{"id": 1, "type": "KSampler"}], "links": []}"#
        let png = try injecting(["workflow": workflow], into: bitmap(.png, width: 5, height: 5))
        let url = try write(png, as: "workflow.png")

        let result = MediaMetadataExtractor.extract(from: url)

        XCTAssertEqual(result.sourcePlatform, "ComfyUI")
        XCTAssertEqual(result.width, 5)
        XCTAssertEqual(result.prompt, "")
    }

    /// A change here is deliberate: bump `parserVersion` with every change to extraction output.
    func testParserVersion() {
        XCTAssertEqual(MediaMetadataExtractor.parserVersion, 1)
    }

    // MARK: - Builders

    private func bitmap(_ type: TestImage.FileType, width: Int, height: Int) throws -> Data {
        try XCTUnwrap(TestImage.data(type, width: width, height: height))
    }

    private func write(_ data: Data, as name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// Inserts tEXt chunks before IEND.
    private func injecting(_ chunks: [String: String], into png: Data) throws -> Data {
        var data = png
        let iend = try XCTUnwrap(data.range(of: Data("IEND".utf8)))
        var extra = Data()
        for (keyword, text) in chunks.sorted(by: { $0.key < $1.key }) {
            var body = Data(keyword.utf8)
            body.append(0)
            body.append(Data(text.utf8))
            extra.append(chunk(type: "tEXt", body: body))
        }
        data.insert(contentsOf: extra, at: iend.lowerBound - 4)
        return data
    }

    private func chunk(type: String, body: Data) -> Data {
        var out = Data()
        var length = UInt32(body.count).bigEndian
        out.append(Data(bytes: &length, count: 4))
        var crcInput = Data(type.utf8)
        crcInput.append(body)
        out.append(crcInput)
        var crc = crc32(crcInput).bigEndian
        out.append(Data(bytes: &crc, count: 4))
        return out
    }

    private func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xEDB8_8320 : 0) }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
