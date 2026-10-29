import ImageIO
import XCTest
@testable import AIGenerationMetadata

/// Platform-detection false positives: an ordinary photo's EXIF UserComment
/// mislabeled as an Automatic1111 prompt, and a Fooocus/SwarmUI JSON blob sitting in the
/// `parameters` chunk stored verbatim as an A1111 prompt.
final class PlatformDetectionTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("PlatformDetectionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - EXIF UserComment false positives

    func testOrdinaryEXIFCommentIsNotLabelledAutomatic1111() throws {
        let url = try makeJPEG(named: "family.jpg", userComment: "Family holiday")

        let result = MediaMetadataExtractor.extract(from: url)

        XCTAssertNotEqual(result.sourcePlatform, "Automatic1111")
        XCTAssertTrue(result.sourcePlatform.isEmpty)
        XCTAssertTrue(result.prompt.isEmpty)
    }

    func testGenuineA1111EXIFCommentIsStillDetected() throws {
        // Regression guard: EXIF/JPEG A1111 output (the format this fix must not break)
        // always carries a "Steps:" line.
        let comment = "a cat\nSteps: 20, Sampler: Euler a, CFG scale: 7, Seed: 1, Model: x"
        let url = try makeJPEG(named: "a1111.jpg", userComment: comment)

        let result = MediaMetadataExtractor.extract(from: url)

        XCTAssertEqual(result.sourcePlatform, "Automatic1111")
        XCTAssertEqual(result.prompt, "a cat")
        XCTAssertEqual(result.steps, 20)
    }

    // MARK: - JSON-in-parameters false positives

    func testFooocusJSONInParametersIsNotStoredAsAnA1111Prompt() throws {
        // Fooocus's default metadata scheme writes a JSON object (with a "base_model"
        // key, among others) into the same `parameters` tEXt chunk A1111 uses.
        let fooocusJSON = """
        {
            "prompt": "a cat",
            "negative_prompt": "ugly",
            "base_model": "juggernautXL_v8.safetensors",
            "performance": "Speed",
            "seed": "12345"
        }
        """
        let url = try makePNG(named: "fooocus.png", textChunks: ["parameters": fooocusJSON])

        let result = MediaMetadataExtractor.extract(from: url)

        XCTAssertNotEqual(result.sourcePlatform, "Automatic1111")
        XCTAssertEqual(result.sourcePlatform, "Fooocus")
        XCTAssertNotEqual(result.prompt, fooocusJSON, "The whole JSON blob must not be stored as the prompt")
    }

    func testSwarmUIJSONInParametersIsNotStoredAsAnA1111Prompt() throws {
        // SwarmUI writes its parameters as JSON under a "sui_image_params" key.
        let swarmJSON = """
        {
            "sui_image_params": {
                "prompt": "a cat",
                "negativeprompt": "ugly",
                "steps": 20,
                "cfgscale": 7,
                "seed": 12345,
                "model": "juggernautXL_v8"
            }
        }
        """
        let url = try makePNG(named: "swarmui.png", textChunks: ["parameters": swarmJSON])

        let result = MediaMetadataExtractor.extract(from: url)

        XCTAssertNotEqual(result.sourcePlatform, "Automatic1111")
        XCTAssertEqual(result.sourcePlatform, "SwarmUI")
        XCTAssertNotEqual(result.prompt, swarmJSON, "The whole JSON blob must not be stored as the prompt")
    }

    func testUnrecognisedJSONInParametersIsLeftUnclassifiedRatherThanMislabelled() throws {
        // Conservative fallback: JSON with no recognised marker key must not be guessed
        // at, and must never be labelled Automatic1111.
        let unknownJSON = #"{"some_other_tool_field": "value"}"#
        let url = try makePNG(named: "unknown.png", textChunks: ["parameters": unknownJSON])

        let result = MediaMetadataExtractor.extract(from: url)

        XCTAssertNotEqual(result.sourcePlatform, "Automatic1111")
        XCTAssertTrue(result.prompt.isEmpty)
    }

    func testGenuineA1111ParametersChunkIsStillDetected() throws {
        // Regression guard: plain-text A1111 parameters (not JSON) must keep working.
        let parameters = "a cat\nSteps: 20, Sampler: Euler a, CFG scale: 7, Seed: 1, Model: x"
        let url = try makePNG(named: "a1111.png", textChunks: ["parameters": parameters])

        let result = MediaMetadataExtractor.extract(from: url)

        XCTAssertEqual(result.sourcePlatform, "Automatic1111")
        XCTAssertEqual(result.prompt, "a cat")
    }

    // MARK: - JPEG builder (EXIF UserComment)

    private func makeJPEG(named name: String, userComment: String) throws -> URL {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: 4, height: 4,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let cgImage = ctx.makeImage()!

        let url = tempDir.appendingPathComponent(name)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else {
            throw TestError.destinationCreationFailed
        }
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: userComment]
        ]
        CGImageDestinationAddImage(dest, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw TestError.destinationCreationFailed }
        return url
    }

    // MARK: - Fooocus and SwarmUI parameters

    /// As Fooocus 2.5 writes it (modules/meta_parser.py `FooocusMetadataParser.to_string`, fed by
    /// modules/async_worker.py `save_and_log`; checked against upstream main 2026-09-29): sorted
    /// keys, `steps` an int, `guidance_scale` a float, `seed` a string, `base_model` a file name.
    private static let fooocusJSON = #"""
    {"adm_guidance": "(1.5, 0.8, 0.3)", "base_model": "juggernautXL_v8Rundiffusion.safetensors", "base_model_hash": "aeb7e9e689", "full_negative_prompt": ["ugly, blurry"], "full_prompt": ["a cat on a sofa, cinematic, detailed"], "guidance_scale": 4.0, "loras": [["sd_xl_offset_example-lora_1.0.safetensors", 0.1, "4852686128"]], "metadata_scheme": "fooocus", "negative_prompt": "ugly, blurry", "performance": "Speed", "prompt": "a cat on a sofa", "prompt_expansion": "a cat on a sofa, cinematic, detailed", "refiner_switch": 0.5, "resolution": "(1152, 896)", "sampler": "dpmpp_2m_sde_gpu", "scheduler": "karras", "seed": "8761241190328417", "sharpness": 2.0, "steps": 30, "styles": "['Fooocus V2', 'Fooocus Enhance']", "vae": "Default (model)", "version": "Fooocus v2.5.5"}
    """#

    /// As SwarmUI writes it (src/Text2Image/T2IParamInput.cs `GenFullMetadataObject`, keys being
    /// parameter IDs from T2IParamTypes.cs cleaned to lowercase letters; checked 2026-09-29):
    /// the model is its cleaned name, `seed` a long, `steps` an int, `cfgscale` a double.
    private static let swarmJSON = #"""
    {"sui_image_params": {"prompt": "a cat on a sofa <embed:goodstyle>", "negativeprompt": "ugly, blurry", "model": "OfficialStableDiffusion/sd_xl_base_1.0", "seed": 9007199254740993, "steps": 25, "cfgscale": 6.5, "aspectratio": "1:1", "width": 1024, "height": 1024, "sampler": "dpmpp_2m", "scheduler": "karras", "automaticvae": true, "swarm_version": "0.9.6.2"}, "sui_extra_data": {"date": "2026-09-29", "prep_time": "0.21 sec", "generation_time": "4.87 sec"}, "sui_models": [{"name": "OfficialStableDiffusion/sd_xl_base_1.0.safetensors", "param": "model", "hash": "0x31e35c80fc4829d14f90153f4c74cd59c90b779f6afe05a74cd6120b893f7e5b"}]}
    """#

    private func assertFooocusFields(_ result: ExtractedMediaMetadata, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(result.sourcePlatform, "Fooocus", file: file, line: line)
        XCTAssertEqual(result.prompt, "a cat on a sofa", "the prompt as typed, not the expanded full_prompt", file: file, line: line)
        XCTAssertEqual(result.negativePrompt, "ugly, blurry", file: file, line: line)
        XCTAssertEqual(result.model, "juggernautXL_v8Rundiffusion.safetensors", file: file, line: line)
        XCTAssertEqual(result.steps, 30, file: file, line: line)
        XCTAssertEqual(result.guidanceScale, 4.0, file: file, line: line)
        XCTAssertEqual(result.sampler, "dpmpp_2m_sde_gpu", file: file, line: line)
        XCTAssertEqual(result.scheduler, "karras", file: file, line: line)
        XCTAssertEqual(result.seed, "8761241190328417", file: file, line: line)
    }

    func testFooocusParametersAreParsedFromPNG() throws {
        let url = try makePNG(named: "fooocus-full.png", textChunks: ["parameters": Self.fooocusJSON, "fooocus_scheme": "fooocus"])
        assertFooocusFields(MediaMetadataExtractor.extract(from: url))
    }

    func testFooocusParametersAreParsedFromJPEGUserComment() throws {
        // The JSON in the standard UserComment place, written by ImageIO. Fooocus's own
        // Pillow-written layout (IFD0, ASCII) is covered by FooocusPillowEXIFTests.
        let url = try makeJPEG(named: "fooocus-full.jpg", userComment: Self.fooocusJSON)
        assertFooocusFields(MediaMetadataExtractor.extract(from: url))
    }

    func testSwarmUIParametersAreParsed() throws {
        let url = try makePNG(named: "swarm-full.png", textChunks: ["parameters": Self.swarmJSON])

        let result = MediaMetadataExtractor.extract(from: url)

        XCTAssertEqual(result.sourcePlatform, "SwarmUI")
        XCTAssertEqual(result.prompt, "a cat on a sofa <embed:goodstyle>")
        XCTAssertEqual(result.negativePrompt, "ugly, blurry")
        XCTAssertEqual(result.model, "OfficialStableDiffusion/sd_xl_base_1.0")
        XCTAssertEqual(result.steps, 25)
        XCTAssertEqual(result.guidanceScale, 6.5)
        XCTAssertEqual(result.sampler, "dpmpp_2m")
        XCTAssertEqual(result.scheduler, "karras")
        XCTAssertEqual(result.seed, "9007199254740993", "a long seed above 2^53 keeps every digit")
    }

    func testSwarmUIWithOnlySomeParametersKeepsTheRestEmpty() throws {
        let url = try makePNG(named: "swarm-min.png", textChunks: ["parameters": #"{"sui_image_params": {"prompt": "a fox", "steps": "12"}}"#])

        let result = MediaMetadataExtractor.extract(from: url)

        XCTAssertEqual(result.sourcePlatform, "SwarmUI")
        XCTAssertEqual(result.prompt, "a fox")
        XCTAssertEqual(result.steps, 12, "a numeric string is read too")
        XCTAssertEqual(result.model, "")
        XCTAssertEqual(result.seed, "")
    }

    func testJSONUserCommentFromAnotherToolIsNotClassified() throws {
        let url = try makeJPEG(named: "other.jpg", userComment: #"{"some_other_tool_field": "value"}"#)
        let result = MediaMetadataExtractor.extract(from: url)
        XCTAssertEqual(result.sourcePlatform, "")
        XCTAssertEqual(result.prompt, "")
    }

    // MARK: - PNG builder (tEXt chunks)

    private func makePNG(named name: String, textChunks: [String: String]) throws -> URL {
        var pngData = try XCTUnwrap(TestImage.data(.png, width: 1, height: 1))

        let iendMarker = Data([0x49, 0x45, 0x4E, 0x44]) // "IEND"
        guard let iendTypeRange = pngData.range(of: iendMarker) else {
            throw TestError.invalidPNG
        }
        let insertionPoint = iendTypeRange.lowerBound - 4

        var chunksData = Data()
        for (keyword, text) in textChunks.sorted(by: { $0.key < $1.key }) {
            var chunkBody = Data(keyword.utf8)
            chunkBody.append(0)
            chunkBody.append(Data(text.utf8))
            chunksData.append(buildPNGChunk(type: "tEXt", body: chunkBody))
        }
        pngData.insert(contentsOf: chunksData, at: insertionPoint)

        let url = tempDir.appendingPathComponent(name)
        try pngData.write(to: url)
        return url
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

    private enum TestError: Error {
        case invalidPNG
        case destinationCreationFailed
    }
}
