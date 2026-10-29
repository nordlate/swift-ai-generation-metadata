import CoreGraphics
import Foundation
import ImageIO

/// Small images for the tests, made with Core Graphics and ImageIO so the tests need no AppKit or UIKit.
enum TestImage {
    enum FileType: String {
        case png = "public.png"
        case jpeg = "public.jpeg"
    }

    /// A solid grey RGB image.
    static func cgImage(width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// The encoded bytes of a solid image.
    static func data(_ type: FileType, width: Int, height: Int) -> Data? {
        guard let image = cgImage(width: width, height: height) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.rawValue as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// A 1×1 PNG with `textChunks` as tEXt chunks before IEND, in keyword order.
    static func png(textChunks: [String: String]) -> Data? {
        guard var png = data(.png, width: 1, height: 1), let iend = png.range(of: Data("IEND".utf8)) else { return nil }
        var extra = Data()
        for (keyword, text) in textChunks.sorted(by: { $0.key < $1.key }) {
            extra.append(pngChunk(type: "tEXt", body: Data(keyword.utf8) + [0] + Data(text.utf8)))
        }
        png.insert(contentsOf: extra, at: iend.lowerBound - 4)
        return png
    }

    /// One PNG chunk: length, type, body and CRC.
    static func pngChunk(type: String, body: Data) -> Data {
        let typeAndBody = Data(type.utf8) + body
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in typeAndBody {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xEDB8_8320 : 0) }
        }
        return bigEndian(UInt32(body.count)) + typeAndBody + bigEndian(crc ^ 0xFFFF_FFFF)
    }

    private static func bigEndian(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }
}
