import Compression
import XCTest
@testable import AIGenerationMetadata

final class MediaMetadataExtractorTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ExtractorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Automatic1111

    func testA1111FullMetadata() throws {
        let parameters = """
        masterpiece, best quality, 1girl
        Negative prompt: lowres, bad anatomy
        Steps: 20, Sampler: Euler a, CFG scale: 7, Seed: 12345, Model: sd_xl_base_1.0
        """
        let url = try makePNG(named: "a1111.png", textChunks: ["parameters": parameters])

        let result = MediaMetadataExtractor.extract(from: url)

        XCTAssertEqual(result.sourcePlatform, "Automatic1111")
        XCTAssertEqual(result.prompt, "masterpiece, best quality, 1girl")
        XCTAssertEqual(result.negativePrompt, "lowres, bad anatomy")
        XCTAssertEqual(result.steps, 20)
        XCTAssertEqual(result.sampler, "Euler a")
        XCTAssertEqual(result.guidanceScale, 7)
        XCTAssertEqual(result.seed, "12345")
        XCTAssertEqual(result.model, "sd_xl_base_1.0")
    }

    func testA1111WithEmptyNegativePrompt() throws {
        let parameters = "a beautiful landscape\nNegative prompt: \nSteps: 30, Sampler: DPM++ 2M, CFG scale: 9.5, Seed: 67890, Model: dreamshaper_8"
        let url = try makePNG(named: "a1111_no_neg.png", textChunks: ["parameters": parameters])

        let result = MediaMetadataExtractor.extract(from: url)

        XCTAssertEqual(result.sourcePlatform, "Automatic1111")
        XCTAssertEqual(result.prompt, "a beautiful landscape")
        XCTAssertTrue(result.negativePrompt.isEmpty)
        XCTAssertEqual(result.steps, 30)
        XCTAssertEqual(result.sampler, "DPM++ 2M")
    }

    func testA1111WithoutNegativePromptLineExcludesParametersFromPrompt() throws {
        // A1111/Forge omits the "Negative prompt:" line entirely when it is empty —
        // typical for SDXL and Flux users. The parameters line must not end up in the
        // prompt (and therefore in searchableText).
        let parameters = "a cat\nSteps: 20, Sampler: Euler a, CFG scale: 7, Seed: 1, Model: x"
        let url = try makePNG(named: "a1111_no_neg_line.png", textChunks: ["parameters": parameters])

        let result = MediaMetadataExtractor.extract(from: url)

        XCTAssertEqual(result.prompt, "a cat")
        XCTAssertTrue(result.negativePrompt.isEmpty)
        XCTAssertEqual(result.steps, 20)
        XCTAssertEqual(result.sampler, "Euler a")
        XCTAssertEqual(result.seed, "1")
    }

    func testA1111MultiLinePromptWithoutNegativeKeepsEveryPromptLine() throws {
        let parameters = "a cat\nsitting on a mat\nSteps: 20, Sampler: Euler a, Seed: 1"
        let url = try makePNG(named: "a1111_multiline.png", textChunks: ["parameters": parameters])

        let result = MediaMetadataExtractor.extract(from: url)

        XCTAssertEqual(result.prompt, "a cat\nsitting on a mat")
    }

    func testA1111PromptOnly() throws {
        let parameters = "just a prompt with no parameters line"
        let url = try makePNG(named: "a1111_prompt_only.png", textChunks: ["parameters": parameters])

        let result = MediaMetadataExtractor.extract(from: url)

        XCTAssertEqual(result.sourcePlatform, "Automatic1111")
        XCTAssertEqual(result.prompt, "just a prompt with no parameters line")
        XCTAssertEqual(result.steps, 0)
    }

    // MARK: - ComfyUI

    func testComfyUIFullMetadata() throws {
        let promptJSON = """
        {
            "3": {
                "class_type": "KSampler",
                "inputs": {
                    "steps": 25,
                    "cfg": 8.0,
                    "sampler_name": "euler",
                    "seed": 42,
                    "positive": ["6", 0],
                    "negative": ["7", 0],
                    "model": ["4", 0]
                }
            },
            "4": {
                "class_type": "CheckpointLoaderSimple",
                "inputs": { "ckpt_name": "v1-5-pruned.safetensors" }
            },
            "6": {
                "class_type": "CLIPTextEncode",
                "inputs": { "text": "a cat sitting on a couch" }
            },
            "7": {
                "class_type": "CLIPTextEncode",
                "inputs": { "text": "ugly, blurry" }
            }
        }
        """
        let url = try makePNG(named: "comfyui.png", textChunks: ["prompt": promptJSON])

        let result = MediaMetadataExtractor.extract(from: url)

        XCTAssertEqual(result.sourcePlatform, "ComfyUI")
        XCTAssertEqual(result.prompt, "a cat sitting on a couch")
        XCTAssertEqual(result.negativePrompt, "ugly, blurry")
        XCTAssertEqual(result.steps, 25)
        XCTAssertEqual(result.guidanceScale, 8.0)
        XCTAssertEqual(result.sampler, "euler")
        XCTAssertEqual(result.seed, "42")
        XCTAssertEqual(result.model, "v1-5-pruned.safetensors")
    }

    func testComfyUIKSamplerAdvanced() throws {
        let promptJSON = """
        {
            "1": {
                "class_type": "KSamplerAdvanced",
                "inputs": {
                    "steps": 40,
                    "cfg": 12.0,
                    "sampler_name": "dpmpp_2m",
                    "noise_seed": 7777,
                    "positive": ["2", 0],
                    "negative": ["3", 0],
                    "model": ["4", 0]
                }
            },
            "2": { "class_type": "CLIPTextEncode", "inputs": { "text": "advanced prompt" } },
            "3": { "class_type": "CLIPTextEncode", "inputs": { "text": "bad quality" } },
            "4": { "class_type": "CheckpointLoaderSimple", "inputs": { "ckpt_name": "model.safetensors" } }
        }
        """
        let url = try makePNG(named: "comfyui_advanced.png", textChunks: ["prompt": promptJSON])

        let result = MediaMetadataExtractor.extract(from: url)

        XCTAssertEqual(result.sourcePlatform, "ComfyUI")
        XCTAssertEqual(result.steps, 40)
        XCTAssertEqual(result.prompt, "advanced prompt")
        XCTAssertEqual(result.seed, "7777")
    }

    // MARK: - InvokeAI

    func testInvokeAIFullMetadata() throws {
        let invokeJSON = """
        {
            "positive_prompt": "a serene mountain landscape",
            "negative_prompt": "blurry",
            "model": { "model_name": "stable-diffusion-xl" },
            "steps": 50,
            "cfg_scale": 7.5,
            "scheduler": "ddim",
            "seed": 999
        }
        """
        let url = try makePNG(named: "invokeai.png", textChunks: ["invokeai_metadata": invokeJSON])

        let result = MediaMetadataExtractor.extract(from: url)

        XCTAssertEqual(result.sourcePlatform, "InvokeAI")
        XCTAssertEqual(result.prompt, "a serene mountain landscape")
        XCTAssertEqual(result.negativePrompt, "blurry")
        XCTAssertEqual(result.model, "stable-diffusion-xl")
        XCTAssertEqual(result.steps, 50)
        XCTAssertEqual(result.guidanceScale, 7.5)
        XCTAssertEqual(result.sampler, "ddim")
        XCTAssertEqual(result.seed, "999")
    }

    // MARK: - InvokeAI Legacy

    func testInvokeAILegacyFormat() throws {
        let legacyJSON = """
        {
            "image": {
                "prompt": "a futuristic city",
                "steps": 40,
                "cfg_scale": 12.0,
                "sampler": "k_lms",
                "seed": 555
            }
        }
        """
        let url = try makePNG(named: "invoke_legacy.png", textChunks: ["sd-metadata": legacyJSON])

        let result = MediaMetadataExtractor.extract(from: url)

        XCTAssertEqual(result.sourcePlatform, "InvokeAI")
        XCTAssertEqual(result.prompt, "a futuristic city")
        XCTAssertEqual(result.steps, 40)
        XCTAssertEqual(result.guidanceScale, 12.0)
        XCTAssertEqual(result.sampler, "k_lms")
        XCTAssertEqual(result.seed, "555")
    }

    // MARK: - Midjourney

    func testMidjourneyWithVersion() throws {
        let description = "a cyberpunk street scene --v 5 Job ID: abc-123"
        let url = try makePNG(named: "midjourney.png", textChunks: ["Description": description])

        let result = MediaMetadataExtractor.extract(from: url)

        XCTAssertEqual(result.sourcePlatform, "Midjourney")
        XCTAssertEqual(result.prompt, "a cyberpunk street scene")
        XCTAssertEqual(result.model, "Midjourney v5")
    }

    func testMidjourneyNiji() throws {
        let description = "anime character --niji 5 Job ID: xyz-456"
        let url = try makePNG(named: "niji.png", textChunks: ["Description": description])

        let result = MediaMetadataExtractor.extract(from: url)

        XCTAssertEqual(result.sourcePlatform, "Midjourney")
        XCTAssertEqual(result.model, "Niji v5")
    }

    func testMidjourneyVersionFlag() throws {
        let description = "landscape painting --version 6 Job ID: test-789"
        let url = try makePNG(named: "mj_version.png", textChunks: ["Description": description])

        let result = MediaMetadataExtractor.extract(from: url)

        XCTAssertEqual(result.sourcePlatform, "Midjourney")
        XCTAssertEqual(result.model, "Midjourney v6")
    }

    // MARK: - Edge Cases

    func testPNGWithoutMetadataReturnsEmpty() throws {
        let url = try makePNG(named: "plain.png", textChunks: [:])

        let result = MediaMetadataExtractor.extract(from: url)

        XCTAssertTrue(result.prompt.isEmpty)
        XCTAssertTrue(result.sourcePlatform.isEmpty)
    }

    func testNonImageFileReturnsEmptyMetadata() throws {
        let url = tempDir.appendingPathComponent("file.png")
        try Data("not a png".utf8).write(to: url)

        let result = MediaMetadataExtractor.extract(from: url)

        XCTAssertTrue(result.prompt.isEmpty)
        XCTAssertTrue(result.sourcePlatform.isEmpty)
    }

    func testAspectRatioExtraction() throws {
        let url = try makePNG(named: "wide.png", textChunks: [:], width: 100, height: 50)

        let result = MediaMetadataExtractor.extract(from: url)

        XCTAssertEqual(result.aspectRatio, "2:1")
    }

    func testSquareAspectRatio() throws {
        let url = try makePNG(named: "square.png", textChunks: [:], width: 64, height: 64)

        let result = MediaMetadataExtractor.extract(from: url)

        XCTAssertEqual(result.aspectRatio, "1:1")
    }

    func testAspectRatio16by9() throws {
        let url = try makePNG(named: "hd.png", textChunks: [:], width: 1920, height: 1080)

        let result = MediaMetadataExtractor.extract(from: url)

        XCTAssertEqual(result.aspectRatio, "16:9")
    }

    // MARK: - PNG Builder

    /// Creates a valid PNG file with optional tEXt chunks injected before IEND.
    private func makePNG(
        named name: String,
        textChunks: [String: String],
        width: Int = 1,
        height: Int = 1
    ) throws -> URL {
        var pngData = try XCTUnwrap(TestImage.data(.png, width: width, height: height))

        // Find IEND chunk position (search for "IEND" marker preceded by 4-byte length)
        let iendMarker = Data([0x49, 0x45, 0x4E, 0x44]) // "IEND"
        guard let iendTypeRange = pngData.range(of: iendMarker) else {
            throw TestError.invalidPNG
        }
        let insertionPoint = iendTypeRange.lowerBound - 4 // Before length field

        // Build tEXt chunks to inject
        var chunksData = Data()
        for (keyword, text) in textChunks.sorted(by: { $0.key < $1.key }) {
            var chunkBody = Data(keyword.utf8)
            chunkBody.append(0) // NUL separator
            chunkBody.append(Data(text.utf8))
            chunksData.append(buildPNGChunk(type: "tEXt", body: chunkBody))
        }

        // Insert chunks before IEND
        pngData.insert(contentsOf: chunksData, at: insertionPoint)

        let url = tempDir.appendingPathComponent(name)
        try pngData.write(to: url)
        return url
    }

    private func buildPNGChunk(type: String, body: Data) -> Data {
        var chunk = Data()

        // Length (4 bytes, big-endian)
        var length = UInt32(body.count).bigEndian
        chunk.append(Data(bytes: &length, count: 4))

        // Type (4 bytes)
        let typeData = Data(type.utf8)
        chunk.append(typeData)

        // Body
        chunk.append(body)

        // CRC32 of type + body
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

    private enum TestError: Error {
        case invalidPNG
    }
}
