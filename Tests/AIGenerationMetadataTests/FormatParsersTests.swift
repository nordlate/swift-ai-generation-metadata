import XCTest
@testable import AIGenerationMetadata

/// Direct coverage of `FormatParsers.parseComfyUI` for widget values that have been
/// "converted to input": the ComfyUI editor's context-menu action that turns a
/// KSampler's seed/steps/cfg/denoise widget into a linked input. The API/prompt JSON then
/// holds a link array (`["<node id>", <slot>]`) in place of the literal value, and the
/// literal instead lives on the source node (rgthree's Seed node, or a Primitive node).
final class FormatParsersTests: XCTestCase {

    func testConvertedSeedInputIsResolvedFromLinkedNode() {
        // rgthree's Seed node exposes the seed as its own scalar `seed` input and an
        // INT output; the KSampler's "seed" field becomes a link to it.
        let json = """
        {
            "3": {
                "class_type": "KSampler",
                "inputs": {
                    "steps": 20,
                    "cfg": 7.0,
                    "sampler_name": "euler",
                    "seed": ["10", 0],
                    "positive": ["6", 0],
                    "negative": ["7", 0]
                }
            },
            "6": { "class_type": "CLIPTextEncode", "inputs": { "text": "a cat" } },
            "7": { "class_type": "CLIPTextEncode", "inputs": { "text": "ugly" } },
            "10": { "class_type": "Seed", "inputs": { "seed": 999888777 } }
        }
        """

        let result = FormatParsers.parseComfyUI(json, into: ExtractedMediaMetadata())

        XCTAssertEqual(result.seed, "999888777", "Before the fix this silently dropped to an empty string")
    }

    func testConvertedStepsCfgAndDenoiseInputsAreResolvedFromPrimitiveNodes() {
        // Widget-to-input conversion via a generic Primitive node: its own widget value
        // lives under the "value" key.
        let json = """
        {
            "3": {
                "class_type": "KSampler",
                "inputs": {
                    "steps": ["11", 0],
                    "cfg": ["12", 0],
                    "denoise": ["13", 0],
                    "sampler_name": "euler",
                    "seed": 1,
                    "positive": ["6", 0],
                    "negative": ["7", 0]
                }
            },
            "6": { "class_type": "CLIPTextEncode", "inputs": { "text": "a cat" } },
            "7": { "class_type": "CLIPTextEncode", "inputs": { "text": "ugly" } },
            "11": { "class_type": "PrimitiveNode", "inputs": { "value": 30 } },
            "12": { "class_type": "PrimitiveNode", "inputs": { "value": 6.5 } },
            "13": { "class_type": "PrimitiveNode", "inputs": { "value": 0.85 } }
        }
        """

        let result = FormatParsers.parseComfyUI(json, into: ExtractedMediaMetadata())

        XCTAssertEqual(result.steps, 30, "Before the fix this silently dropped to 0")
        XCTAssertEqual(result.guidanceScale, 6.5, "Before the fix this silently dropped to 0")
        XCTAssertEqual(result.denoise, 0.85, "Before the fix this silently dropped to 0")
    }

    func testOrdinaryLiteralWidgetValuesAreUnaffected() {
        // Regression guard: most workflows never convert these widgets to inputs, so the
        // plain literal path (already covered by MediaMetadataExtractorTests) must keep
        // working unchanged.
        let json = """
        {
            "3": {
                "class_type": "KSampler",
                "inputs": {
                    "steps": 25,
                    "cfg": 8.0,
                    "denoise": 1.0,
                    "sampler_name": "euler",
                    "seed": 42,
                    "positive": ["6", 0],
                    "negative": ["7", 0]
                }
            },
            "6": { "class_type": "CLIPTextEncode", "inputs": { "text": "a cat" } },
            "7": { "class_type": "CLIPTextEncode", "inputs": { "text": "ugly" } }
        }
        """

        let result = FormatParsers.parseComfyUI(json, into: ExtractedMediaMetadata())

        XCTAssertEqual(result.steps, 25)
        XCTAssertEqual(result.guidanceScale, 8.0)
        XCTAssertEqual(result.denoise, 1.0)
        XCTAssertEqual(result.seed, "42")
    }
}
