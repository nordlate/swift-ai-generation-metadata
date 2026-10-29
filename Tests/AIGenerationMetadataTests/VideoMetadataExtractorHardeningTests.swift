import AVFoundation
import XCTest

@testable import AIGenerationMetadata

final class VideoMetadataExtractorHardeningTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Writes a tiny H.264 MP4 of the given size.
    private func makeVideo(name: String, size: Int = 64) async throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size,
            AVVideoHeightKey: size
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size,
            kCVPixelBufferHeightKey as String: size
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<10 {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, size, size, kCVPixelFormatType_32BGRA, nil, &buffer)
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            adaptor.append(try XCTUnwrap(buffer), withPresentationTime: CMTime(value: Int64(frame), timescale: 10))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        return url
    }

    private func put(_ value: UInt32, in data: inout Data, at offset: Int) {
        for i in 0..<4 { data[offset + i] = UInt8((value >> UInt32(24 - 8 * i)) & 0xFF) }
    }

    private func offset(of box: String, in data: Data) throws -> Int {
        let range = try XCTUnwrap(data.range(of: Data(box.utf8)))
        return range.upperBound
    }

    func testNormalVideoKeepsSizeAspectAndDuration() async throws {
        let url = try await makeVideo(name: "normal.mp4")
        let result = await VideoMetadataExtractor.extract(from: url)
        XCTAssertEqual(result.width, 64)
        XCTAssertEqual(result.height, 64)
        XCTAssertEqual(result.aspectRatio, "1:1")
        XCTAssertGreaterThan(result.duration, 0.5)
        XCTAssertLessThan(result.duration, 5)
    }

    func testHugeTkhdMatrixDoesNotTrapAndClampsToInt32() async throws {
        let url = try await makeVideo(name: "matrix.mp4")
        var data = try Data(contentsOf: url)
        let tkhd = try offset(of: "tkhd", in: data)   // version 0 layout
        // The matrix is a, b, u, c, d, v, x, y, w; AVFoundation reads every 16.16 field as signed,
        // so these are the largest values it can produce (a·w + c·h just under 2^31).
        put(0x7FFF_FFFF, in: &data, at: tkhd + 40)    // a
        put(0x7FFF_FFFF, in: &data, at: tkhd + 52)    // c
        put(0x7FFF_FFFF, in: &data, at: tkhd + 76)    // width
        put(0x7FFF_FFFF, in: &data, at: tkhd + 80)    // height
        let crafted = tempDir.appendingPathComponent("crafted-matrix.mp4")
        try data.write(to: crafted)
        let result = await VideoMetadataExtractor.extract(from: crafted)
        XCTAssertGreaterThan(result.width, 2_000_000_000)
        XCTAssertLessThanOrEqual(result.width, Int32.max)
        XCTAssertGreaterThan(result.height, 0)
    }

    func testHugeMvhdDurationIsDropped() async throws {
        let url = try await makeVideo(name: "duration.mp4")
        var data = try Data(contentsOf: url)
        let mvhd = try offset(of: "mvhd", in: data)   // version 0 layout
        put(1, in: &data, at: mvhd + 12)              // timescale
        put(0xFFFF_FFFF, in: &data, at: mvhd + 16)    // duration
        // The edit list's segment duration (in movie timescale units) also feeds the asset duration.
        let elst = try offset(of: "elst", in: data)
        put(0xFFFF_FFFF, in: &data, at: elst + 8)     // segment duration
        let crafted = tempDir.appendingPathComponent("crafted-duration.mp4")
        try data.write(to: crafted)
        let result = await VideoMetadataExtractor.extract(from: crafted)
        XCTAssertEqual(result.duration, 0)
    }
}
