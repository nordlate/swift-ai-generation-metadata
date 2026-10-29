import XCTest
@testable import AIGenerationMetadata

/// `FormatParsers.parseComfyUI` on graphs with more than one path: ControlNet nodes
/// with both positive and negative inputs and outputs, several samplers (base + hires fix),
/// combined conditioning and more than one guidance node. Dictionary order must not matter,
/// so each graph is parsed several times.
final class ComfyUIGraphTracingTests: XCTestCase {

    private func parse(_ json: String) -> ExtractedMediaMetadata {
        FormatParsers.parseComfyUI(json, into: ExtractedMediaMetadata())
    }

    /// Parses repeatedly and requires the same answer every time.
    private func parseConsistently(_ json: String, file: StaticString = #filePath, line: UInt = #line) -> ExtractedMediaMetadata {
        let first = parse(json)
        for _ in 0..<5 {
            let again = parse(json)
            XCTAssertEqual(again.steps, first.steps, file: file, line: line)
            XCTAssertEqual(again.seed, first.seed, file: file, line: line)
            XCTAssertEqual(again.prompt, first.prompt, file: file, line: line)
            XCTAssertEqual(again.negativePrompt, first.negativePrompt, file: file, line: line)
            XCTAssertEqual(again.model, first.model, file: file, line: line)
        }
        return first
    }

    func testNegativePromptThroughControlNetIsTheNegativeText() {
        let json = """
        {
          "3": {"class_type": "KSampler", "inputs": {"seed": 1, "steps": 20, "cfg": 7.0, "sampler_name": "euler",
                "scheduler": "normal", "denoise": 1.0, "model": ["4", 0], "positive": ["10", 0], "negative": ["10", 1],
                "latent_image": ["5", 0]}},
          "4": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": "sd15.safetensors"}},
          "6": {"class_type": "CLIPTextEncode", "inputs": {"text": "a red fox", "clip": ["4", 1]}},
          "7": {"class_type": "CLIPTextEncode", "inputs": {"text": "blurry, watermark", "clip": ["4", 1]}},
          "10": {"class_type": "ControlNetApplyAdvanced", "inputs": {"positive": ["6", 0], "negative": ["7", 0],
                 "control_net": ["11", 0], "image": ["12", 0], "strength": 1.0}}
        }
        """

        let result = parseConsistently(json)

        XCTAssertEqual(result.prompt, "a red fox")
        XCTAssertEqual(result.negativePrompt, "blurry, watermark", "the negative output (slot 1) leads to the negative input")
    }

    func testSettingsComeFromTheSamplerThatProducesTheSavedImage() {
        // Base pass (node 3, 20 steps) → latent upscale → hires pass (node 13, 40 steps) → decode → save.
        let json = """
        {
          "3": {"class_type": "KSampler", "inputs": {"seed": 111, "steps": 20, "cfg": 7.0, "sampler_name": "euler",
                "scheduler": "normal", "denoise": 1.0, "model": ["4", 0], "positive": ["6", 0], "negative": ["7", 0],
                "latent_image": ["5", 0]}},
          "4": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": "base.safetensors"}},
          "6": {"class_type": "CLIPTextEncode", "inputs": {"text": "a lighthouse", "clip": ["4", 1]}},
          "7": {"class_type": "CLIPTextEncode", "inputs": {"text": "lowres", "clip": ["4", 1]}},
          "12": {"class_type": "LatentUpscaleBy", "inputs": {"samples": ["3", 0], "scale_by": 1.5, "upscale_method": "nearest-exact"}},
          "13": {"class_type": "KSampler", "inputs": {"seed": 222, "steps": 40, "cfg": 5.0, "sampler_name": "dpmpp_2m",
                 "scheduler": "karras", "denoise": 0.5, "model": ["4", 0], "positive": ["6", 0], "negative": ["7", 0],
                 "latent_image": ["12", 0]}},
          "8": {"class_type": "VAEDecode", "inputs": {"samples": ["13", 0], "vae": ["4", 2]}},
          "9": {"class_type": "SaveImage", "inputs": {"images": ["8", 0], "filename_prefix": "ComfyUI"}},
          "20": {"class_type": "VAEDecode", "inputs": {"samples": ["3", 0], "vae": ["4", 2]}},
          "21": {"class_type": "PreviewImage", "inputs": {"images": ["20", 0]}}
        }
        """

        let result = parseConsistently(json)

        XCTAssertEqual(result.steps, 40, "the hires pass feeds SaveImage; the base pass only a preview")
        XCTAssertEqual(result.seed, "222")
        XCTAssertEqual(result.denoise, 0.5)
        XCTAssertEqual(result.sampler, "dpmpp_2m")
        XCTAssertEqual(result.prompt, "a lighthouse")
        XCTAssertEqual(result.negativePrompt, "lowres")
    }

    func testWithoutAnOutputNodeTheLastSamplerIsUsed() {
        let json = """
        {
          "3": {"class_type": "KSampler", "inputs": {"seed": 1, "steps": 20, "positive": ["6", 0], "negative": ["7", 0]}},
          "13": {"class_type": "KSampler", "inputs": {"seed": 2, "steps": 30, "positive": ["6", 0], "negative": ["7", 0]}},
          "6": {"class_type": "CLIPTextEncode", "inputs": {"text": "a cabin"}},
          "7": {"class_type": "CLIPTextEncode", "inputs": {"text": "text"}}
        }
        """

        XCTAssertEqual(parseConsistently(json).steps, 30, "highest numeric node id, not dictionary order")
    }

    func testCombinedPositiveConditioningIsTracedAndNeverTheNegativeEncoder() {
        let json = """
        {
          "3": {"class_type": "KSampler", "inputs": {"seed": 5, "steps": 25, "positive": ["10", 0], "negative": ["7", 0]}},
          "6": {"class_type": "CLIPTextEncode", "inputs": {"text": "a snowy forest"}},
          "8": {"class_type": "CLIPTextEncode", "inputs": {"text": "at dawn"}},
          "7": {"class_type": "CLIPTextEncode", "inputs": {"text": "people, text"}},
          "10": {"class_type": "ConditioningCombine", "inputs": {"conditioning_1": ["6", 0], "conditioning_2": ["8", 0]}}
        }
        """

        let result = parseConsistently(json)

        XCTAssertEqual(result.prompt, "a snowy forest")
        XCTAssertEqual(result.negativePrompt, "people, text")
    }

    func testFluxGuidanceWinsOverTheGuidersCFG() {
        let json = """
        {
          "13": {"class_type": "SamplerCustomAdvanced", "inputs": {"noise": ["25", 0], "guider": ["22", 0],
                 "sampler": ["16", 0], "sigmas": ["17", 0], "latent_image": ["27", 0]}},
          "22": {"class_type": "CFGGuider", "inputs": {"model": ["12", 0], "positive": ["26", 0],
                 "negative": ["7", 0], "cfg": 1.0}},
          "26": {"class_type": "FluxGuidance", "inputs": {"guidance": 3.5, "conditioning": ["6", 0]}},
          "6": {"class_type": "CLIPTextEncode", "inputs": {"text": "a harbour at night"}},
          "7": {"class_type": "CLIPTextEncode", "inputs": {"text": ""}},
          "12": {"class_type": "UNETLoader", "inputs": {"unet_name": "flux1-dev.safetensors"}},
          "16": {"class_type": "KSamplerSelect", "inputs": {"sampler_name": "euler"}},
          "17": {"class_type": "BasicScheduler", "inputs": {"steps": 20}},
          "25": {"class_type": "RandomNoise", "inputs": {"noise_seed": 42}}
        }
        """

        XCTAssertEqual(parseConsistently(json).guidanceScale, 3.5)
    }

    func testGuidanceIsTheOneWiredToTheSampler() {
        let json = """
        {
          "13": {"class_type": "SamplerCustomAdvanced", "inputs": {"noise": ["25", 0], "guider": ["22", 0],
                 "sampler": ["16", 0], "sigmas": ["17", 0], "latent_image": ["27", 0]}},
          "22": {"class_type": "BasicGuider", "inputs": {"model": ["12", 0], "conditioning": ["26", 0]}},
          "26": {"class_type": "FluxGuidance", "inputs": {"guidance": 3.5, "conditioning": ["6", 0]}},
          "30": {"class_type": "FluxGuidance", "inputs": {"guidance": 2.0, "conditioning": ["6", 0]}},
          "6": {"class_type": "CLIPTextEncode", "inputs": {"text": "a harbour at night"}},
          "12": {"class_type": "UNETLoader", "inputs": {"unet_name": "flux1-dev.safetensors"}},
          "16": {"class_type": "KSamplerSelect", "inputs": {"sampler_name": "euler"}},
          "17": {"class_type": "BasicScheduler", "inputs": {"steps": 20}},
          "25": {"class_type": "RandomNoise", "inputs": {"noise_seed": 42}}
        }
        """

        let result = parseConsistently(json)

        XCTAssertEqual(result.guidanceScale, 3.5, "node 30 is not connected to the sampler")
        XCTAssertEqual(result.prompt, "a harbour at night")
        XCTAssertEqual(result.model, "flux1-dev.safetensors")
        XCTAssertEqual(result.steps, 20)
        XCTAssertEqual(result.seed, "42")
    }
}
