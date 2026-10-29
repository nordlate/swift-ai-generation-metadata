import Foundation

/// Reads EXIF UserComment straight from a JPEG or WebP file, for files where ImageIO exposes
/// none.
///
/// Fooocus writes its metadata with Pillow's top-level `Image.Exif()`, which puts UserComment
/// (0x9286) in IFD0 as an ASCII value instead of in the EXIF sub-IFD as UNDEFINED; ImageIO then
/// reports no EXIF dictionary at all. This reader accepts both places and both encodings.
///
/// Bounded, since it runs for every JPEG and WebP without an ImageIO comment: JPEG only up to
/// the start of image data within the first `maxJPEGHead` bytes, WebP only chunk headers plus
/// one EXIF chunk of at most `maxExifBlock`, and every offset and count checked.
enum ExifUserCommentReader {
    static let maxJPEGHead = 256 * 1024
    static let maxExifBlock = 1024 * 1024
    static let maxWebPChunks = 64
    static let maxIFDEntries = 512
    /// EXIF UserComment character codes other than UNICODE: ASCII, JIS and undefined.
    private static let characterCodes: Set<[UInt8]> = [Array("ASCII\0\0\0".utf8), Array("JIS\0\0\0\0\0".utf8), [UInt8](repeating: 0, count: 8)]

    static func userComment(from url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 12), head.count >= 4 else { return nil }
        let bytes = [UInt8](head)
        if bytes[0] == 0xFF, bytes[1] == 0xD8 {
            try? handle.seek(toOffset: 0)
            guard let data = try? handle.read(upToCount: maxJPEGHead) else { return nil }
            return jpegExif([UInt8](data)).flatMap(comment(inTIFF:))
        }
        if bytes.count == 12, bytes[0..<4] == [0x52, 0x49, 0x46, 0x46], bytes[8..<12] == [0x57, 0x45, 0x42, 0x50] {
            return webpExif(handle).flatMap(comment(inTIFF:))
        }
        return nil
    }

    // MARK: - Containers

    /// The TIFF block of the first `Exif\0\0` APP1 segment before the image data.
    static func jpegExif(_ data: [UInt8]) -> [UInt8]? {
        var index = 2
        while index + 4 <= data.count {
            guard data[index] == 0xFF else { return nil }
            let marker = data[index + 1]
            if marker == 0xFF { index += 1; continue }  // fill byte
            if marker == 0xD8 || marker == 0x01 || (0xD0...0xD7).contains(marker) { index += 2; continue }
            if marker == 0xDA || marker == 0xD9 { return nil }  // image data or end: no EXIF before it
            let length = Int(data[index + 2]) << 8 | Int(data[index + 3])
            guard length >= 2, index + 2 + length <= data.count else { return nil }
            let segment = data[(index + 4)..<(index + 2 + length)]
            if marker == 0xE1, segment.starts(with: Array("Exif\0\0".utf8)) {
                return Array(segment.dropFirst(6))
            }
            index += 2 + length
        }
        return nil
    }

    /// The TIFF block of the `EXIF` chunk, seeking past every other chunk.
    static func webpExif(_ handle: FileHandle) -> [UInt8]? {
        var offset: UInt64 = 12
        for _ in 0..<maxWebPChunks {
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let header = try? handle.read(upToCount: 8), header.count == 8 else { return nil }
            let bytes = [UInt8](header)
            let size = UInt64(bytes[4]) | UInt64(bytes[5]) << 8 | UInt64(bytes[6]) << 16 | UInt64(bytes[7]) << 24
            if bytes[0..<4] == [0x45, 0x58, 0x49, 0x46] {  // "EXIF"
                guard size <= UInt64(maxExifBlock), let body = try? handle.read(upToCount: Int(size)),
                      body.count == Int(size) else { return nil }
                let block = [UInt8](body)
                // Some writers keep JPEG's "Exif\0\0" prefix inside the chunk.
                return block.starts(with: Array("Exif\0\0".utf8)) ? Array(block.dropFirst(6)) : block
            }
            offset += 8 + size + (size & 1)
        }
        return nil
    }

    // MARK: - TIFF

    /// One IFD entry: its TIFF type, value count, and where the value starts in the block.
    private struct IFDEntry {
        let type: Int
        let count: Int
        let valueAt: Int
    }

    /// UserComment from IFD0 (Pillow) or the EXIF sub-IFD (the standard place).
    static func comment(inTIFF tiff: [UInt8]) -> String? {
        guard tiff.count >= 8 else { return nil }
        let little: Bool
        switch (tiff[0], tiff[1]) {
        case (0x49, 0x49): little = true
        case (0x4D, 0x4D): little = false
        default: return nil
        }
        func u16(_ at: Int) -> Int? {
            guard at >= 0, at + 2 <= tiff.count else { return nil }
            return little ? Int(tiff[at]) | Int(tiff[at + 1]) << 8 : Int(tiff[at]) << 8 | Int(tiff[at + 1])
        }
        func u32(_ at: Int) -> Int? {
            guard let high = u16(little ? at + 2 : at), let low = u16(little ? at : at + 2) else { return nil }
            return high << 16 | low
        }
        guard u16(2) == 42, let ifd0 = u32(4) else { return nil }

        /// The entry for `tag` in the IFD at `ifd`: its type, count and value's offset.
        func entry(_ tag: Int, in ifd: Int) -> IFDEntry? {
            guard let entries = u16(ifd), entries <= maxIFDEntries else { return nil }
            for index in 0..<entries {
                let at = ifd + 2 + index * 12
                guard let found = u16(at), let type = u16(at + 2), let count = u32(at + 4) else { return nil }
                guard found == tag else { continue }
                let byteCount = count * (type == 3 ? 2 : type == 4 ? 4 : 1)
                return IFDEntry(type: type, count: count, valueAt: byteCount <= 4 ? at + 8 : (u32(at + 8) ?? -1))
            }
            return nil
        }

        func decode(_ found: IFDEntry) -> String? {
            guard found.type == 2 || found.type == 7, found.count <= maxExifBlock,
                  found.valueAt >= 0, found.valueAt + found.count <= tiff.count else { return nil }
            var value = Array(tiff[found.valueAt..<(found.valueAt + found.count)])
            // UNDEFINED starts with an 8-byte character code (EXIF 2.3, 4.6.5); strip only a known one.
            if found.type == 7, value.count >= 8 {
                let code = Array(value.prefix(8))
                if code == Array("UNICODE\0".utf8) {
                    return String(bytes: value.dropFirst(8), encoding: little ? .utf16LittleEndian : .utf16BigEndian)
                }
                if Self.characterCodes.contains(code) { value.removeFirst(8) }
            }
            if let end = value.firstIndex(of: 0) { value.removeSubrange(end...) }
            return String(bytes: value, encoding: .utf8) ?? String(bytes: value, encoding: .isoLatin1)
        }

        let userComment = 0x9286
        if let found = entry(userComment, in: ifd0), let text = decode(found) { return text }
        if let pointer = entry(0x8769, in: ifd0), pointer.type == 4, let exifIFD = u32(pointer.valueAt),
           let found = entry(userComment, in: exifIFD) {
            return decode(found)
        }
        return nil
    }
}
