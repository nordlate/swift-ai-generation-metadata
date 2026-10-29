import Compression
import Foundation

// MARK: - PNG Chunks

enum PNGChunkParser {
    private static let pngSignature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
    private static let textChunkTypes: Set<String> = ["tEXt", "zTXt", "iTXt"]
    /// Generation metadata runs to a few KB; 16 MB is far beyond any real text chunk.
    private static let maxTextChunkLength = 16 * 1024 * 1024
    /// IHDR is fixed by the spec at 13 bytes; any other length is corrupt or hostile.
    private static let ihdrLength = 13
    /// The spec limits keywords to 79 bytes; the keyword is read before the rest of a chunk.
    private static let maxKeywordLength = 79

    /// The keywords `MediaMetadataExtractor.applyTextChunks` reads. Other text chunks are
    /// skipped before their text is read or decompressed.
    static let supportedKeywords: Set<String> = [
        "parameters", "prompt", "invokeai_metadata", "sd-metadata", "Description", "workflow"
    ]
    /// Budget for all text one image contributes, after decompression and including repeated
    /// keywords. Per-chunk limits alone let many valid chunks add up without bound.
    static let maxTotalTextBytes = 32 * 1024 * 1024
    /// Text chunks examined per image, supported or not.
    static let maxTextChunks = 64

    struct PNGParseResult {
        var width: Int = 0
        var height: Int = 0
        var aspectRatio: String = ""
        var textChunks: [String: String] = [:]
        /// Text was skipped because the image exceeded the text byte or chunk budget; the
        /// chunks read before that are kept.
        var textBudgetExhausted = false
    }

    private struct TextBudget {
        var bytes = maxTotalTextBytes
        var chunks = maxTextChunks
    }

    /// Single-pass PNG parser: extracts dimensions from IHDR and text chunks in one file open.
    /// `additionalKeywords` are read besides `supportedKeywords`.
    static func parse(from url: URL, additionalKeywords: Set<String> = []) -> PNGParseResult {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return PNGParseResult() }
        defer { try? handle.close() }

        guard let sig = try? handle.read(upToCount: 8),
              sig.count == 8,
              [UInt8](sig) == pngSignature
        else { return PNGParseResult() }

        var result = PNGParseResult()
        var budget = TextBudget()
        let keywords = supportedKeywords.union(additionalKeywords)

        while let header = try? handle.read(upToCount: 8), header.count == 8 {
            let length = Int(header.readUInt32BE(at: 0))
            let type = String(bytes: header[4..<8], encoding: .ascii) ?? ""

            if type == "IEND" { break }

            if textChunkTypes.contains(type) {
                guard readTextChunk(handle: handle, type: type, length: length, keywords: keywords, budget: &budget, result: &result) else { break }
            } else {
                guard let chunkData = readChunkIfNeeded(handle: handle, type: type, length: length) else { break }
                processChunk(type: type, data: chunkData, result: &result)
            }
            guard (try? handle.seek(toOffset: handle.offsetInFile + 4)) != nil else { break }
        }

        return result
    }

    private static func readChunkIfNeeded(handle: FileHandle, type: String, length: Int) -> Data? {
        // A chunk length is an attacker-controlled UInt32, so a chunk whose declared
        // length exceeds what its type can legitimately carry is skipped rather than
        // read into memory.
        if type == "IHDR" && length == ihdrLength {
            guard let data = try? handle.read(upToCount: length), data.count == length else { return nil }
            return data
        }
        // Skip unneeded (or oversized) chunk data — seek past data, CRC read by caller
        guard (try? handle.seek(toOffset: handle.offsetInFile + UInt64(length))) != nil else { return nil }
        return Data()
    }

    /// Reads one text chunk within the image's budget, leaving the handle at its CRC.
    /// Returns false when the file cannot be read any further.
    private static func readTextChunk(
        handle: FileHandle, type: String, length: Int, keywords: Set<String>, budget: inout TextBudget,
        result: inout PNGParseResult
    ) -> Bool {
        let end = handle.offsetInFile + UInt64(length)
        let skip = { (try? handle.seek(toOffset: end)) != nil }
        guard length <= maxTextChunkLength else { return skip() }
        guard budget.chunks > 0, budget.bytes > 0 else {
            result.textBudgetExhausted = true
            return skip()
        }
        budget.chunks -= 1

        let headLength = min(length, maxKeywordLength + 1)
        guard let head = try? handle.read(upToCount: headLength), head.count == headLength else { return false }
        guard let nul = head.firstIndex(of: 0),
              let keyword = String(data: head[head.startIndex..<nul], encoding: type == "iTXt" ? .utf8 : .isoLatin1),
              keywords.contains(keyword)
        else { return skip() }

        var data = head
        if length > headLength {
            guard let rest = try? handle.read(upToCount: length - headLength), rest.count == length - headLength else { return false }
            data.append(rest)
        }

        switch parseChunk(type: type, data: data, limit: budget.bytes) {
        case .parsed(let key, let text) where text.utf8.count <= budget.bytes:
            // The limit bounds the chunk's own bytes; Latin-1 text can grow up to twice that
            // as a Swift string, so the budget is charged, and checked, in retained bytes.
            budget.bytes -= text.utf8.count
            result.textChunks[key] = text
        case .parsed, .overBudget:
            budget.bytes = 0
            result.textBudgetExhausted = true
        case .invalid:
            break
        }
        return true
    }

    private static func processChunk(type: String, data: Data, result: inout PNGParseResult) {
        guard type == "IHDR", data.count >= 8 else { return }
        let w = Int(data.readUInt32BE(at: 0))
        let h = Int(data.readUInt32BE(at: 4))
        // The PNG spec caps dimensions at 2^31-1; a larger value is a corrupt or
        // hostile header, and narrowing it to Int32 downstream would trap.
        guard w > 0, h > 0, w <= Int(Int32.max), h <= Int(Int32.max) else { return }
        result.width = w
        result.height = h
        result.aspectRatio = reducedAspectRatio(w, h)
    }

    private enum ChunkText {
        case parsed(String, String)
        /// The text would exceed the image's remaining budget.
        case overBudget
        case invalid
    }

    /// `limit` is the remaining text budget in bytes; decompression stops once it is reached.
    private static func parseChunk(type: String, data: Data, limit: Int) -> ChunkText {
        switch type {
        case "tEXt": return parseTEXt(data, limit: limit)
        case "zTXt": return parseZTXt(data, limit: limit)
        case "iTXt": return parseITXt(data, limit: limit)
        default: return .invalid
        }
    }

    private static func parseTEXt(_ data: Data, limit: Int) -> ChunkText {
        guard let nul = data.firstIndex(of: 0) else { return .invalid }
        let keyword = String(data: data[data.startIndex..<nul], encoding: .isoLatin1) ?? ""
        let start = data.index(after: nul)
        guard data.endIndex - start <= limit else { return .overBudget }
        let text = start < data.endIndex
            ? String(data: data[start...], encoding: .isoLatin1) ?? "" : ""
        return .parsed(keyword, text)
    }

    private static func parseZTXt(_ data: Data, limit: Int) -> ChunkText {
        guard let nul = data.firstIndex(of: 0) else { return .invalid }
        let keyword = String(data: data[data.startIndex..<nul], encoding: .isoLatin1) ?? ""
        let compIdx = data.index(after: nul)
        guard compIdx < data.endIndex else { return .invalid }
        let start = data.index(after: compIdx)
        guard start < data.endIndex else { return .parsed(keyword, "") }
        return decompressed(Data(data[start...]), limit: limit) { .parsed(keyword, String(data: $0, encoding: .isoLatin1) ?? "") }
    }

    private static func parseITXt(_ data: Data, limit: Int) -> ChunkText {
        guard let nul = data.firstIndex(of: 0) else { return .invalid }
        let keyword = String(data: data[data.startIndex..<nul], encoding: .utf8) ?? ""
        var pos = data.index(after: nul)
        guard pos < data.endIndex else { return .invalid }
        let compFlag = data[pos]
        pos = data.index(after: pos)
        guard pos < data.endIndex else { return .invalid }
        pos = data.index(after: pos)
        guard let langNul = data[pos...].firstIndex(of: 0) else { return .invalid }
        pos = data.index(after: langNul)
        guard let transNul = data[pos...].firstIndex(of: 0) else { return .invalid }
        pos = data.index(after: transNul)
        guard pos <= data.endIndex else { return .invalid }
        let textData = data[pos...]
        if compFlag == 1 {
            return decompressed(Data(textData), limit: limit) { .parsed(keyword, String(data: $0, encoding: .utf8) ?? "") }
        }
        guard textData.count <= limit else { return .overBudget }
        return .parsed(keyword, String(data: textData, encoding: .utf8) ?? "")
    }

    private static func decompressed(_ data: Data, limit: Int, _ text: (Data) -> ChunkText) -> ChunkText {
        switch ZlibHelper.decompress(data, limit: limit) {
        case .success(let output): text(output)
        case .overLimit: .overBudget
        case .invalid: .invalid
        }
    }
}

// MARK: - Zlib Decompression

private enum ZlibHelper {
    /// Hard cap on decompressed text. Deflate reaches roughly 1000:1, so an unbounded
    /// decode turns a small crafted zTXt/iTXt chunk into a multi-gigabyte allocation.
    private static let maxDecompressedSize = 32 * 1024 * 1024
    private static let outputBufferSize = 64 * 1024

    enum Outcome {
        case success(Data)
        /// The output would exceed the limit; decoding stopped there.
        case overLimit
        case invalid
    }

    /// Decodes a zlib stream in a single bounded pass, giving up once the output would
    /// exceed `limit` (at most `maxDecompressedSize`) rather than retrying with ever larger
    /// buffers.
    static func decompress(_ data: Data, limit: Int) -> Outcome {
        let limit = min(limit, maxDecompressedSize)
        let src = stripHeader(data)
        guard !src.isEmpty else { return .invalid }

        // compression_stream has no public empty initializer; init fills every field.
        let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPointer.deallocate() }
        var stream = streamPointer.pointee
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
            == COMPRESSION_STATUS_OK else { return .invalid }
        defer { compression_stream_destroy(&stream) }

        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: outputBufferSize)
        defer { buffer.deallocate() }

        var output = Data()
        return src.withUnsafeBytes { raw -> Outcome in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return .invalid }
            stream.src_ptr = base
            stream.src_size = raw.count

            while true {
                stream.dst_ptr = buffer
                stream.dst_size = outputBufferSize
                let remainingInput = stream.src_size

                let status = compression_stream_process(
                    &stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
                )
                guard status != COMPRESSION_STATUS_ERROR else { return .invalid }

                let produced = outputBufferSize - stream.dst_size
                guard output.count + produced <= limit else { return .overLimit }
                output.append(buffer, count: produced)

                // An empty result is a legitimately empty text chunk, not a decode failure —
                // failing here would drop the keyword entirely and make zTXt/iTXt behave
                // differently from an equally empty tEXt.
                if status == COMPRESSION_STATUS_END { return .success(output) }
                // Neither output nor input consumed and no end marker: a truncated or
                // malformed stream. Bail rather than spin.
                if produced == 0, stream.src_size == remainingInput { return .invalid }
            }
        }
    }

    private static func stripHeader(_ data: Data) -> Data {
        guard data.count >= 2, (data[data.startIndex] & 0x0F) == 8 else { return data }
        return data.dropFirst(2)
    }
}

private extension Data {
    func readUInt32BE(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        var val: UInt32 = 0
        _ = Swift.withUnsafeMutableBytes(of: &val) { buf in
            guard let base = buf.baseAddress else { return }
            copyBytes(to: base.assumingMemoryBound(to: UInt8.self), from: offset..<(offset + 4))
        }
        return UInt32(bigEndian: val)
    }
}
