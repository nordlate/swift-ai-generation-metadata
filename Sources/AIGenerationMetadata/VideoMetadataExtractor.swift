import AVFoundation
import CoreMedia
import Foundation

/// Reads AI generation metadata and track properties from video files (MP4, MOV and anything
/// else AVFoundation opens).
///
/// Duration, frame rate, displayed size and codec come from the first video track; generation
/// metadata comes from the container's text metadata items (such as the comment a ComfyUI
/// VideoHelperSuite save node writes), read as ComfyUI, Runway or A1111-style text.
public enum VideoMetadataExtractor {
    /// Longest duration (seconds) kept from a file; anything beyond is treated as corrupt and
    /// reported as 0.
    public static let maxDuration: Double = 1e8

    /// Reads the generation metadata and track properties of the video at `url`.
    ///
    /// A missing, unreadable or unrecognised file returns empty metadata with `codec` set to an
    /// empty string, rather than throwing.
    public static func extract(from url: URL) async -> ExtractedMediaMetadata {
        var result = ExtractedMediaMetadata()
        result.codec = ""
        let asset = AVURLAsset(url: url)

        // Duration
        if let duration = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(duration)
            // A crafted mvhd can yield inf, NaN or an absurd length.
            if seconds.isFinite, seconds >= 0, seconds <= maxDuration {
                result.duration = seconds
            }
        }

        // Video track properties
        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            if let frameRate = try? await track.load(.nominalFrameRate) {
                result.frameRate = Double(frameRate)
            }

            if let naturalSize = try? await track.load(.naturalSize),
               let preferredTransform = try? await track.load(.preferredTransform) {
                let size = naturalSize.applying(preferredTransform)
                // The tkhd matrix can push the transformed size past Int32; clamp like the image path.
                if size.width.isFinite, size.height.isFinite,
                   let w = Int(exactly: min(abs(size.width), Double(Int32.max)).rounded(.towardZero)),
                   let h = Int(exactly: min(abs(size.height), Double(Int32.max)).rounded(.towardZero)),
                   w > 0, h > 0 {
                    result.width = Int32(clamping: w)
                    result.height = Int32(clamping: h)
                    result.aspectRatio = reducedAspectRatio(w, h)
                }
            }

            // Codec FourCC
            if let descs = try? await track.load(.formatDescriptions),
               let fmtDesc = descs.first {
                let mediaSubType = CMFormatDescriptionGetMediaSubType(fmtDesc)
                result.codec = fourCCString(mediaSubType)
            }
        }

        // Embedded metadata (AI platform)
        await extractAIMetadata(from: asset, into: &result)

        return result
    }

    // MARK: - AI metadata from AVMetadataItem

    private static func extractAIMetadata(from asset: AVURLAsset, into result: inout ExtractedMediaMetadata) async {
        guard let metadata = try? await asset.load(.metadata) else { return }
        var textValues: [String] = []
        for item in metadata {
            if let str = try? await item.load(.stringValue), !str.isEmpty {
                textValues.append(str)
            }
        }
        guard !textValues.isEmpty else { return }
        // The parsers know only generation fields; the track's size, rate and codec stay.
        var merged = parseAIMetadata(from: textValues)
        merged.aspectRatio = result.aspectRatio
        merged.width = result.width
        merged.height = result.height
        merged.duration = result.duration
        merged.frameRate = result.frameRate
        merged.codec = result.codec
        result = merged
    }

    /// Platform detection from the text values of a container's metadata items; the first recognised value wins.
    static func parseAIMetadata(from textValues: [String]) -> ExtractedMediaMetadata {
        var result = ExtractedMediaMetadata()
        for text in textValues {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            let json = trimmed.hasPrefix("{")
                ? trimmed.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                : nil

            // ComfyUI video wrapper whose "prompt" is the node graph as JSON text (VideoHelperSuite):
            // checked before Runway, which also has a string "prompt".
            if let json, json["prompt"] is String, FormatParsers.promptGraph(in: json) != nil {
                return comfyUIMetadata(from: trimmed)
            }

            // Runway: JSON with "prompt" key
            if let json, let prompt = json["prompt"] as? String {
                result.prompt = prompt
                result.model = json["model"] as? String ?? ""
                result.sourcePlatform = "Runway"
                return result
            }

            // ComfyUI video: JSON with "class_type"
            if trimmed.hasPrefix("{"), trimmed.contains("\"class_type\"") {
                return comfyUIMetadata(from: trimmed)
            }

            // A1111-style: text containing "Steps:"
            if trimmed.contains("Steps:") {
                var parsed = FormatParsers.parseA1111(trimmed, into: ExtractedMediaMetadata())
                parsed.sourcePlatform = "Automatic1111"
                return parsed
            }
        }
        return result
    }

    private static func comfyUIMetadata(from json: String) -> ExtractedMediaMetadata {
        var parsed = FormatParsers.parseComfyUI(json, into: ExtractedMediaMetadata())
        parsed.sourcePlatform = "ComfyUI"
        return parsed
    }

    // MARK: - Helpers

    static func gcd(_ a: Int, _ b: Int) -> Int { numericGCD(a, b) }

    static func fourCCString(_ value: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? String(value)
    }
}
