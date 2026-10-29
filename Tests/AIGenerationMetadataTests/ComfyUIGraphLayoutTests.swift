import XCTest
@testable import AIGenerationMetadata

/// ComfyUI graph layouts beyond KSampler and BasicGuider: CFGGuider, SamplerCustom,
/// linked encoder text and CLIPTextEncodeSDXL.
final class ComfyUIGraphLayoutTests: XCTestCase {

    private func comfyResult(_ graph: String) -> ExtractedMediaMetadata {
        FormatParsers.parseComfyUI(graph, into: ExtractedMediaMetadata())
    }

    func testComfyUICFGGuiderNegativeEncoderWithLowerID() {
        let result = comfyResult("""
        {
            "1": { "class_type": "CLIPTextEncode", "inputs": { "text": "bad quality" } },
            "2": { "class_type": "CLIPTextEncode", "inputs": { "text": "a fox" } },
            "3": { "class_type": "CFGGuider", "inputs": { "cfg": 4.5, "positive": ["2", 0], "negative": ["1", 0], "model": ["6", 0] } },
            "4": { "class_type": "RandomNoise", "inputs": { "noise_seed": 99 } },
            "5": { "class_type": "SamplerCustomAdvanced", "inputs": { "noise": ["4", 0], "guider": ["3", 0] } },
            "6": { "class_type": "UNETLoader", "inputs": { "unet_name": "sd35.safetensors" } }
        }
        """)
        XCTAssertEqual(result.prompt, "a fox")
        XCTAssertEqual(result.negativePrompt, "bad quality")
        XCTAssertEqual(result.guidanceScale, 4.5)
        XCTAssertEqual(result.seed, "99")
        XCTAssertEqual(result.model, "sd35.safetensors")
    }

    func testComfyUISamplerCustom() {
        let result = comfyResult("""
        {
            "1": { "class_type": "CLIPTextEncode", "inputs": { "text": "bad" } },
            "2": { "class_type": "CLIPTextEncode", "inputs": { "text": "a owl" } },
            "3": { "class_type": "SamplerCustom", "inputs": {
                "noise_seed": 123, "cfg": 6.5, "positive": ["2", 0], "negative": ["1", 0],
                "sampler": ["4", 0], "sigmas": ["5", 0], "model": ["6", 0] } },
            "4": { "class_type": "KSamplerSelect", "inputs": { "sampler_name": "euler" } },
            "5": { "class_type": "BasicScheduler", "inputs": { "steps": 20 } },
            "6": { "class_type": "CheckpointLoaderSimple", "inputs": { "ckpt_name": "m.safetensors" } }
        }
        """)
        XCTAssertEqual(result.prompt, "a owl")
        XCTAssertEqual(result.negativePrompt, "bad")
        XCTAssertEqual(result.seed, "123")
        XCTAssertEqual(result.guidanceScale, 6.5)
        XCTAssertEqual(result.sampler, "euler")
        XCTAssertEqual(result.steps, 20)
        XCTAssertEqual(result.model, "m.safetensors")
    }

    func testComfyUILinkedAndSDXLEncoderText() {
        let result = comfyResult("""
        {
            "1": { "class_type": "KSampler", "inputs": { "seed": 1, "steps": 10, "cfg": 7.0,
                "positive": ["2", 0], "negative": ["3", 0] } },
            "2": { "class_type": "CLIPTextEncode", "inputs": { "text": ["4", 0] } },
            "3": { "class_type": "CLIPTextEncodeSDXL", "inputs": { "text_g": "blurry", "text_l": "blurry" } },
            "4": { "class_type": "String Literal", "inputs": { "string": "linked prompt" } }
        }
        """)
        XCTAssertEqual(result.prompt, "linked prompt")
        XCTAssertEqual(result.negativePrompt, "blurry")
    }

    func testComfyUIFallbackSkipsGuiderNegativeEncoder() {
        let result = comfyResult("""
        {
            "1": { "class_type": "CLIPTextEncode", "inputs": { "text": "bad quality" } },
            "2": { "class_type": "CLIPTextEncode", "inputs": { "text": ["7", 0] } },
            "3": { "class_type": "CFGGuider", "inputs": { "cfg": 3.0, "positive": ["2", 0], "negative": ["1", 0] } },
            "4": { "class_type": "RandomNoise", "inputs": { "noise_seed": 5 } },
            "5": { "class_type": "SamplerCustomAdvanced", "inputs": { "noise": ["4", 0], "guider": ["3", 0] } },
            "6": { "class_type": "CLIPTextEncodeSDXL", "inputs": { "text_g": "fallback prompt", "text_l": "fallback prompt" } },
            "7": { "class_type": "Text Concatenate", "inputs": { "text_a": "x" } }
        }
        """)
        XCTAssertEqual(result.prompt, "fallback prompt")
        XCTAssertEqual(result.negativePrompt, "bad quality")
    }
}
