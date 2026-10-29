import Foundation
import ImageIO
import os

/// A PNG text chunk that marks files written by a particular tool.
///
/// Some tools write A1111-style `parameters` so that other readers understand their images,
/// plus a chunk of their own that says where the image came from. Register such a chunk to
/// label those images with the tool's name instead of `Automatic1111`.
public struct PNGProvenanceMarker: Sendable, Hashable {
    /// The tEXt, zTXt or iTXt keyword the tool writes. Its content is not interpreted.
    public var keyword: String
    /// The value ``ExtractedMediaMetadata/sourcePlatform`` takes for a matching file.
    public var platform: String

    /// A marker that labels PNGs holding both a `parameters` chunk and a `keyword` chunk as `platform`.
    public init(keyword: String, platform: String) {
        self.keyword = keyword
        self.platform = platform
    }
}

/// Reads AI generation metadata and dimensions from still images (PNG, JPEG, WebP and
/// anything else ImageIO opens).
///
/// The file's leading bytes, not its extension, pick the reader. PNGs are read in one pass over
/// their chunks (IHDR plus tEXt, zTXt and iTXt); JPEG and WebP metadata comes from EXIF
/// UserComment. Every read is bounded, so damaged or hostile files cost little and never trap.
public enum MediaMetadataExtractor {
    /// The version of what ``extract(from:provenanceMarkers:)`` and
    /// ``VideoMetadataExtractor/extract(from:)`` produce. It goes up whenever a change to the
    /// package can give a different result for the same file, so a caller that stores results
    /// can re-read files extracted by an older version.
    ///
    /// 1: first release.
    public static let parserVersion = 1

    /// Reads the generation metadata and the displayed dimensions of the image at `url`.
    ///
    /// Runs synchronously and does file I/O; call it off the main thread for many files.
    /// A missing, unreadable or unrecognised file returns empty metadata rather than throwing.
    ///
    /// - Parameters:
    ///   - url: A file URL.
    ///   - provenanceMarkers: Chunks that label PNGs from a particular tool; see ``PNGProvenanceMarker``.
    ///     The first marker present in the file wins.
    public static func extract(
        from url: URL, provenanceMarkers: [PNGProvenanceMarker] = []
    ) -> ExtractedMediaMetadata {
        extract(from: url, provenanceMarkers: provenanceMarkers, readUserComment: ExifUserCommentReader.userComment(from:))
    }

    /// `readUserComment` reads the EXIF block directly when ImageIO exposes none; tests replace it
    /// to see when the file is opened a second time.
    static func extract(
        from url: URL, provenanceMarkers: [PNGProvenanceMarker] = [], readUserComment: (URL) -> String?
    ) -> ExtractedMediaMetadata {
        var result = ExtractedMediaMetadata()
        let ext = url.pathExtension.lowercased()
        let signature = fileSignature(of: url)
        var parsedPNG = false
        if signature == .png || (signature == .other && ext == "png") {
            // Single pass: dimensions from IHDR and the text chunks in one file open.
            let parsed = PNGChunkParser.parse(from: url, additionalKeywords: Set(provenanceMarkers.map(\.keyword)))
            if parsed.textBudgetExhausted {
                Logger.extraction.notice("Skipped PNG metadata over the per-image budget in \(url.lastPathComponent, privacy: .private)")
            }
            result.width = Int32(clamping: parsed.width)
            result.height = Int32(clamping: parsed.height)
            result.aspectRatio = parsed.aspectRatio
            applyTextChunks(parsed.textChunks, provenanceMarkers: provenanceMarkers, into: &result)
            // Without a usable IHDR the dimensions come from ImageIO, which may read the file anyway.
            parsedPNG = result.width > 0 && result.height > 0
            if !parsedPNG, signature == .png { return withImageIODimensions(of: url, into: result) }
        }
        if !parsedPNG, signature != .png {
            // One image source per file: its properties give the dimensions and the EXIF.
            let props = imageProperties(of: url)
            let dims = computeDimensions(from: props)
            result.width = Int32(clamping: dims.width)
            result.height = Int32(clamping: dims.height)
            result.aspectRatio = dims.aspectRatio
            let exifFormat = signature == .jpeg || signature == .webp
                || (signature == .other && ["jpg", "jpeg", "webp"].contains(ext))
            if exifFormat {
                extractFromEXIF(url: url, properties: props, readUserComment: readUserComment, into: &result)
            }
        }
        return result
    }
}

struct ImageDimensions {
    let width: Int
    let height: Int
    let aspectRatio: String
}

// MARK: - Top-level Dispatch

private extension MediaMetadataExtractor {
    static func applyTextChunks(
        _ chunks: [String: String], provenanceMarkers: [PNGProvenanceMarker], into result: inout ExtractedMediaMetadata
    ) {
        // A chunk whose data is not recognised leaves the platform empty and the next one is tried.
        if let parameters = chunks["parameters"] {
            applyParametersChunk(parameters, into: &result)
        } else if let promptJSON = chunks["prompt"], FormatParsers.isComfyUIGraph(promptJSON) {
            result = FormatParsers.parseComfyUI(promptJSON, into: result)
            result.sourcePlatform = "ComfyUI"
        } else if let invokeJSON = chunks["invokeai_metadata"], FormatParsers.isInvokeAI(invokeJSON) {
            result = FormatParsers.parseInvokeAI(invokeJSON, into: result)
            result.sourcePlatform = "InvokeAI"
        } else if let legacyJSON = chunks["sd-metadata"], FormatParsers.isInvokeAILegacy(legacyJSON) {
            result = FormatParsers.parseInvokeAILegacy(legacyJSON, into: result)
            result.sourcePlatform = "InvokeAI"
        } else if let desc = chunks["Description"], desc.contains("Job ID:") {
            result = FormatParsers.parseMidjourney(desc, into: result)
            result.sourcePlatform = "Midjourney"
        } else if let workflow = chunks["workflow"], FormatParsers.isJSONObject(workflow) {
            // UI-format workflow only: identified, fields are not extracted from it yet.
            result.sourcePlatform = "ComfyUI"
        }
        // A tool that writes A1111-style `parameters` plus its own provenance chunk is labelled
        // with its own name, not Automatic1111.
        if chunks["parameters"] != nil, let marker = provenanceMarkers.first(where: { chunks[$0.keyword] != nil }) {
            result.sourcePlatform = marker.platform
        }
    }

    static func withImageIODimensions(of url: URL, into result: ExtractedMediaMetadata) -> ExtractedMediaMetadata {
        var result = result
        let dims = computeDimensions(from: imageProperties(of: url))
        result.width = Int32(clamping: dims.width)
        result.height = Int32(clamping: dims.height)
        result.aspectRatio = dims.aspectRatio
        return result
    }

    enum FileSignature { case png, jpeg, webp, other }

    static func fileSignature(of url: URL) -> FileSignature {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .other }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 12) else { return .other }
        let bytes = [UInt8](head)
        if bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) { return .png }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
        if bytes.count == 12, bytes.starts(with: Array("RIFF".utf8)), Array(bytes[8..<12]) == Array("WEBP".utf8) { return .webp }
        return .other
    }

    static func imageProperties(of url: URL) -> [CFString: Any]? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
    }

    static func extractFromEXIF(
        url: URL, properties: [CFString: Any]?, readUserComment: (URL) -> String?, into result: inout ExtractedMediaMetadata
    ) {
        let exif = properties?[kCGImagePropertyExifDictionary] as? [CFString: Any]
        // Fooocus's Pillow-written EXIF keeps UserComment in IFD0, where ImageIO does not read it
        // and so reports no EXIF dictionary at all; only then read the EXIF block directly, which
        // spares the second open of the many files that have EXIF without a comment.
        // Known gap: a Fooocus file another tool tagged later (exiftool, say) has an EXIF
        // dictionary as well, and its IFD0 comment is not read. ImageIO exposes nothing of IFD0
        // for these files (not even `Software`), so no property tells them from a camera JPEG
        // without opening every one of those a second time.
        // The same read runs when the dictionary lists a UserComment that ImageIO did not hand
        // over as text; an empty string is final, like a missing key.
        var found = exif?[kCGImagePropertyExifUserComment] as? String
        if exif == nil || (found == nil && exif?[kCGImagePropertyExifUserComment] != nil) {
            found = readUserComment(url)
        }
        guard let comment = found else { return }
        // Fooocus writes the same JSON into UserComment for JPEG and WebP as into PNG `parameters`.
        if applyGeneratorJSON(comment, into: &result) { return }
        // An ordinary camera/phone/editor UserComment ("Family holiday", timestamps,
        // copyright notices, ...) is not A1111 generation metadata. A1111/Forge always
        // emit a "Steps:" line, and when there IS a negative prompt a "Negative prompt:"
        // line as well; require one of those markers before treating the comment as a
        // prompt, instead of labelling any non-empty comment Automatic1111.
        guard comment.contains("Steps:") || comment.contains("Negative prompt:") else { return }
        result = FormatParsers.parseA1111(comment, into: result)
        if !result.prompt.isEmpty { result.sourcePlatform = "Automatic1111" }
    }

    /// A `parameters` tEXt/EXIF chunk is A1111/Forge's own format (`prompt\nNegative
    /// prompt: ...\nSteps: ...`), but Fooocus (default scheme) and SwarmUI both write a
    /// JSON object into the same chunk name. Feeding that JSON to `parseA1111` finds no
    /// `Steps:` line and stores the whole blob as the prompt under a wrong platform
    /// label. Detect JSON up front and dispatch on a marker key that is unique to each
    /// tool; an unrecognised JSON shape is left unclassified rather than guessed at.
    static func applyParametersChunk(_ parameters: String, into result: inout ExtractedMediaMetadata) {
        if applyGeneratorJSON(parameters, into: &result) { return }
        result = FormatParsers.parseA1111(parameters, into: result)
        result.sourcePlatform = "Automatic1111"
    }

    /// Reads a JSON object from `parameters` or EXIF UserComment, dispatching on the marker
    /// key unique to each tool. Returns whether the text was a JSON object; unrecognised JSON
    /// is left unclassified rather than mislabelled A1111.
    static func applyGeneratorJSON(_ text: String, into result: inout ExtractedMediaMetadata) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        if let params = object["sui_image_params"] as? [String: Any] {
            result = FormatParsers.parseSwarmUI(params, into: result)
            result.sourcePlatform = "SwarmUI"
        } else if object["base_model"] != nil {
            result = FormatParsers.parseFooocus(object, into: result)
            result.sourcePlatform = "Fooocus"
        }
        return true
    }

    static func computeDimensions(from props: [CFString: Any]?) -> ImageDimensions {
        guard let props,
              let storedWidth = props[kCGImagePropertyPixelWidth] as? Int,
              let storedHeight = props[kCGImagePropertyPixelHeight] as? Int,
              storedWidth > 0, storedHeight > 0
        else { return ImageDimensions(width: 0, height: 0, aspectRatio: "") }
        // Pixel width/height are the stored dimensions. EXIF orientations 5–8 rotate by 90°,
        // and thumbnails and viewers apply that, so report the displayed size.
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let (width, height) = orientation >= 5 ? (storedHeight, storedWidth) : (storedWidth, storedHeight)
        return ImageDimensions(width: width, height: height, aspectRatio: reducedAspectRatio(width, height))
    }
}

extension Logger {
    static let extraction = Logger(subsystem: "com.nordlate.AIGenerationMetadata", category: "Extraction")
}
