import Foundation

/// What one image or video file says about how it was generated, plus its size.
///
/// Every field has an "absent" value: an empty string, or 0 for numbers. A file without
/// recognised generation metadata leaves `sourcePlatform` and the generation fields empty and
/// still reports its dimensions. Numbers are clamped to the `Int32` range.
public struct ExtractedMediaMetadata: Sendable, Hashable, Codable {
    /// The positive prompt as the tool stored it.
    public var prompt: String = ""
    /// The negative prompt; empty when the tool has none or the file omits it.
    public var negativePrompt: String = ""
    /// The checkpoint or model name, usually a file name such as `sd_xl_base_1.0.safetensors`.
    public var model: String = ""
    /// The sampler name as the tool spells it, such as `Euler a` or `dpmpp_2m`.
    public var sampler: String = ""
    /// The scheduler (noise schedule) name, such as `karras`.
    public var scheduler: String = ""
    /// Sampling steps.
    public var steps: Int32 = 0
    /// Denoising strength; ComfyUI only.
    public var denoise: Double = 0
    /// CFG scale, or the Flux guidance value when the workflow sets one.
    public var guidanceScale: Double = 0
    /// The seed as text, so 64-bit unsigned seeds keep every digit.
    public var seed: String = ""
    /// The tool the metadata was recognised as: `Automatic1111`, `ComfyUI`, `InvokeAI`,
    /// `Fooocus`, `SwarmUI`, `Midjourney` or `Runway`, or a ``PNGProvenanceMarker/platform``
    /// the caller registered. Empty when nothing was recognised.
    public var sourcePlatform: String = ""
    /// The reduced width:height ratio of the displayed image, such as `16:9`; empty when unknown.
    public var aspectRatio: String = ""
    /// Displayed width in pixels (EXIF rotation applied); 0 when unknown.
    public var width: Int32 = 0
    /// Displayed height in pixels (EXIF rotation applied); 0 when unknown.
    public var height: Int32 = 0
    /// Video duration in seconds; 0 for images and for unreadable or implausible durations.
    public var duration: Double = 0
    /// Nominal video frame rate; 0 for images.
    public var frameRate: Double = 0
    /// The video track's codec as a four-character code, such as `avc1`. `nil` for images,
    /// empty for a video without a readable video track.
    public var codec: String?

    /// Empty metadata.
    public init() {}
}

/// Greatest common divisor, for reducing aspect ratios.
func numericGCD(_ a: Int, _ b: Int) -> Int { b == 0 ? a : numericGCD(b, a % b) }

/// `width:height` reduced by their greatest common divisor; both must be positive.
func reducedAspectRatio(_ width: Int, _ height: Int) -> String {
    let d = numericGCD(width, height)
    return "\(width / d):\(height / d)"
}
