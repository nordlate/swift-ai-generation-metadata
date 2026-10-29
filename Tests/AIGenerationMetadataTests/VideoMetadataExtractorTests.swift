import XCTest
@testable import AIGenerationMetadata

final class VideoMetadataExtractorTests: XCTestCase {

    // MARK: - gcd

    func testGCDCommonDivisors() {
        XCTAssertEqual(VideoMetadataExtractor.gcd(12, 8), 4)
        XCTAssertEqual(VideoMetadataExtractor.gcd(100, 75), 25)
        XCTAssertEqual(VideoMetadataExtractor.gcd(1, 1), 1)
    }

    func testGCDCommonVideoResolutions() {
        XCTAssertEqual(VideoMetadataExtractor.gcd(1920, 1080), 120) // 16:9
        XCTAssertEqual(VideoMetadataExtractor.gcd(1280, 720), 80)   // 16:9
        XCTAssertEqual(VideoMetadataExtractor.gcd(1024, 768), 256)  // 4:3
        XCTAssertEqual(VideoMetadataExtractor.gcd(2560, 1440), 160) // 16:9
    }

    func testGCDCoprimePair() {
        XCTAssertEqual(VideoMetadataExtractor.gcd(7, 13), 1)
        XCTAssertEqual(VideoMetadataExtractor.gcd(17, 5), 1)
    }

    func testGCDWithZero() {
        XCTAssertEqual(VideoMetadataExtractor.gcd(0, 5), 5)
        XCTAssertEqual(VideoMetadataExtractor.gcd(5, 0), 5)
    }

    // MARK: - Aspect ratio math (using gcd)

    func testAspectRatio16x9() {
        let w = 1920, h = 1080
        let d = VideoMetadataExtractor.gcd(w, h)
        XCTAssertEqual("\(w / d):\(h / d)", "16:9")
    }

    func testAspectRatio4x3() {
        let w = 1024, h = 768
        let d = VideoMetadataExtractor.gcd(w, h)
        XCTAssertEqual("\(w / d):\(h / d)", "4:3")
    }

    func testAspectRatioSquare() {
        let w = 1024, h = 1024
        let d = VideoMetadataExtractor.gcd(w, h)
        XCTAssertEqual("\(w / d):\(h / d)", "1:1")
    }

    // MARK: - fourCCString

    func testFourCCStringH264() {
        // 'avc1' = 0x61766331
        let code: FourCharCode = (UInt32(UInt8(ascii: "a")) << 24)
            | (UInt32(UInt8(ascii: "v")) << 16)
            | (UInt32(UInt8(ascii: "c")) << 8)
            | UInt32(UInt8(ascii: "1"))
        XCTAssertEqual(VideoMetadataExtractor.fourCCString(code), "avc1")
    }

    func testFourCCStringHEVC() {
        // 'hvc1' = 0x68766331
        let code: FourCharCode = (UInt32(UInt8(ascii: "h")) << 24)
            | (UInt32(UInt8(ascii: "v")) << 16)
            | (UInt32(UInt8(ascii: "c")) << 8)
            | UInt32(UInt8(ascii: "1"))
        XCTAssertEqual(VideoMetadataExtractor.fourCCString(code), "hvc1")
    }

    // MARK: - parseAIMetadata: Runway

    func testRunwayDetectsPromptAndModel() {
        let json = #"{"prompt": "a cinematic rocket launch", "model": "gen3a_turbo"}"#
        let result = VideoMetadataExtractor.parseAIMetadata(from: [json])
        XCTAssertEqual(result.sourcePlatform, "Runway")
        XCTAssertEqual(result.prompt, "a cinematic rocket launch")
        XCTAssertEqual(result.model, "gen3a_turbo")
    }

    func testRunwayWithoutModelFieldIsEmpty() {
        let json = #"{"prompt": "waves crashing on a beach"}"#
        let result = VideoMetadataExtractor.parseAIMetadata(from: [json])
        XCTAssertEqual(result.sourcePlatform, "Runway")
        XCTAssertEqual(result.prompt, "waves crashing on a beach")
        XCTAssertTrue(result.model.isEmpty)
    }

    func testRunwayNotTriggeredForJSONWithoutPromptKey() {
        let json = #"{"description": "some info", "version": 2}"#
        let result = VideoMetadataExtractor.parseAIMetadata(from: [json])
        XCTAssertNotEqual(result.sourcePlatform, "Runway")
    }

    // MARK: - parseAIMetadata: ComfyUI

    /// Older VideoHelperSuite versions write the MP4 comment as
    /// `{"prompt": {node graph}, "workflow": {…}}`.
    func testLegacyVideoHelperSuiteWrapperIsParsed() {
        let comment = """
        {"prompt": {
           "3": {"class_type": "KSampler", "inputs": {"seed": 4242, "steps": 24, "cfg": 6.0, "sampler_name": "euler",
                 "positive": ["6", 0], "negative": ["7", 0], "model": ["4", 0]}},
           "4": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": "animatediff.safetensors"}},
           "6": {"class_type": "CLIPTextEncode", "inputs": {"text": "waves on a beach"}},
           "7": {"class_type": "CLIPTextEncode", "inputs": {"text": "static"}}
         },
         "workflow": {"nodes": [{"id": 3, "type": "KSampler"}], "links": []}}
        """

        let result = VideoMetadataExtractor.parseAIMetadata(from: [comment])

        XCTAssertEqual(result.sourcePlatform, "ComfyUI")
        XCTAssertEqual(result.prompt, "waves on a beach")
        XCTAssertEqual(result.negativePrompt, "static")
        XCTAssertEqual(result.steps, 24)
        XCTAssertEqual(result.seed, "4242")
        XCTAssertEqual(result.model, "animatediff.safetensors")
    }

    private static let apiGraph = """
    {"3": {"class_type": "KSampler", "inputs": {"seed": 4242, "steps": 24, "cfg": 6.0, "sampler_name": "euler",
           "scheduler": "karras", "denoise": 0.75, "positive": ["6", 0], "negative": ["7", 0], "model": ["4", 0]}},
     "4": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": "animatediff.safetensors"}},
     "6": {"class_type": "CLIPTextEncode", "inputs": {"text": "waves on a beach"}},
     "7": {"class_type": "CLIPTextEncode", "inputs": {"text": "static"}}}
    """

    /// The VideoHelperSuite comment with the graph as a JSON string; the shape is unconfirmed
    /// against a real file.
    private func stringPromptComment(withWorkflow: Bool) throws -> String {
        var root: [String: Any] = ["prompt": Self.apiGraph]
        if withWorkflow { root["workflow"] = ["nodes": [["id": 3, "type": "KSampler"]], "links": []] }
        return try String(bytes: JSONSerialization.data(withJSONObject: root), encoding: .utf8) ?? ""
    }

    func testVideoHelperSuiteStringPromptReadsAsComfyUI() throws {
        for withWorkflow in [true, false] {
            let result = VideoMetadataExtractor.parseAIMetadata(from: [try stringPromptComment(withWorkflow: withWorkflow)])

            XCTAssertEqual(result.sourcePlatform, "ComfyUI")
            XCTAssertEqual(result.prompt, "waves on a beach")
            XCTAssertEqual(result.negativePrompt, "static")
            XCTAssertEqual(result.steps, 24)
            XCTAssertEqual(result.seed, "4242")
            XCTAssertEqual(result.model, "animatediff.safetensors")
        }
    }

    func testComfyUIVideoKeepsSchedulerAndDenoise() throws {
        let string = VideoMetadataExtractor.parseAIMetadata(from: [try stringPromptComment(withWorkflow: true)])
        let object = VideoMetadataExtractor.parseAIMetadata(from: [#"{"prompt": \#(Self.apiGraph)}"#])

        for result in [string, object] {
            XCTAssertEqual(result.sourcePlatform, "ComfyUI")
            XCTAssertEqual(result.scheduler, "karras")
            XCTAssertEqual(result.denoise, 0.75)
        }
    }

    func testRunwayPromptThatLooksLikeBracesStaysRunway() {
        let json = #"{"prompt": "{a man} walks", "model": "gen3a_turbo"}"#
        let result = VideoMetadataExtractor.parseAIMetadata(from: [json])
        XCTAssertEqual(result.sourcePlatform, "Runway")
        XCTAssertEqual(result.prompt, "{a man} walks")
    }

    func testComfyUIDetectedByClassType() {
        let json = #"{"nodes": [{"class_type": "KSampler"}]}"#
        let result = VideoMetadataExtractor.parseAIMetadata(from: [json])
        XCTAssertEqual(result.sourcePlatform, "ComfyUI")
    }

    // MARK: - parseAIMetadata: Automatic1111

    func testA1111DetectedByStepsKeyword() {
        let text = """
        cinematic landscape, fog
        Negative prompt: ugly, blurry
        Steps: 25, Sampler: DPM++ 2M Karras, CFG scale: 7.5, Seed: 98765, Model: deliberate_v3
        """
        let result = VideoMetadataExtractor.parseAIMetadata(from: [text])
        XCTAssertEqual(result.sourcePlatform, "Automatic1111")
        XCTAssertEqual(result.prompt, "cinematic landscape, fog")
        XCTAssertEqual(result.negativePrompt, "ugly, blurry")
        XCTAssertEqual(result.steps, 25)
        XCTAssertEqual(result.seed, "98765")
        XCTAssertEqual(result.sampler, "DPM++ 2M Karras")
        XCTAssertEqual(result.model, "deliberate_v3")
    }

    func testA1111KeepsScheduleType() {
        let text = """
        cinematic landscape, fog
        Steps: 25, Sampler: DPM++ 2M, Schedule type: Karras, CFG scale: 7.5, Seed: 98765
        """
        let result = VideoMetadataExtractor.parseAIMetadata(from: [text])
        XCTAssertEqual(result.scheduler, "Karras")
    }

    // MARK: - parseAIMetadata: edge cases

    func testUnrecognizedTextReturnsEmptyPlatform() {
        let result = VideoMetadataExtractor.parseAIMetadata(from: ["some random video description"])
        XCTAssertTrue(result.sourcePlatform.isEmpty)
        XCTAssertTrue(result.prompt.isEmpty)
    }

    func testEmptyArrayReturnsEmpty() {
        let result = VideoMetadataExtractor.parseAIMetadata(from: [])
        XCTAssertTrue(result.sourcePlatform.isEmpty)
    }

    func testWhitespaceOnlyTextSkipped() {
        let result = VideoMetadataExtractor.parseAIMetadata(from: ["   \n\t  "])
        XCTAssertTrue(result.sourcePlatform.isEmpty)
    }

    func testFirstMatchWins() {
        // Runway JSON comes first — A1111 text should be ignored
        let runway = #"{"prompt": "runway prompt", "model": "gen3a"}"#
        let a1111 = "a1111 prompt\nSteps: 10, Sampler: Euler a, CFG scale: 7, Seed: 1, Model: foo"
        let result = VideoMetadataExtractor.parseAIMetadata(from: [runway, a1111])
        XCTAssertEqual(result.sourcePlatform, "Runway")
        XCTAssertEqual(result.prompt, "runway prompt")
    }
}
