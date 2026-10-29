import XCTest
@testable import AIGenerationMetadata

/// One text budget per image, covering repeated and unknown keywords.
extension MediaMetadataExtractorHardeningTests {

    func testUnknownCompressedKeywordsAreSkippedWithoutInflating() throws {
        // The review's fixture: eight 8 MiB zTXt chunks under keywords nothing reads.
        let bomb = try compressedTextChunk(keyword: "x", byteCount: 8 * 1024 * 1024)
        var chunks: [(String, Data)] = [("IHDR", validIHDR())]
        for index in 0..<8 {
            chunks.append(("zTXt", try compressedTextChunk(keyword: "junk\(index)", reusing: bomb)))
        }
        chunks.append(("tEXt", Data("parameters\u{0}a cat\nSteps: 12".utf8)))
        let url = try makeRawPNG(named: "unknown_keywords.png", chunks: chunks)

        let parsed = PNGChunkParser.parse(from: url)

        XCTAssertEqual(Array(parsed.textChunks.keys), ["parameters"])
        XCTAssertFalse(parsed.textBudgetExhausted)
        XCTAssertEqual(MediaMetadataExtractor.extract(from: url).steps, 12)
    }

    func testRepeatedKeywordsShareOneBudget() throws {
        // Each chunk is valid on its own; together they exceed the per-image budget.
        let chunk = try compressedTextChunk(keyword: "parameters", byteCount: 8 * 1024 * 1024)
        let chunks = [("IHDR", validIHDR())] + Array(repeating: ("zTXt", chunk), count: 8)
        let url = try makeRawPNG(named: "repeated_keywords.png", chunks: chunks)

        let parsed = PNGChunkParser.parse(from: url)

        XCTAssertTrue(parsed.textBudgetExhausted)
        let retained = parsed.textChunks.values.reduce(0) { $0 + $1.utf8.count }
        XCTAssertLessThanOrEqual(retained, PNGChunkParser.maxTotalTextBytes)
        XCTAssertNotNil(parsed.textChunks["parameters"], "Text read before the budget ran out is kept")
    }

    func testChunkOverTheRemainingBudgetIsDroppedAndLaterTextSkipped() throws {
        // 30 MiB is read; a 4 MiB chunk no longer fits, and nothing after it is read.
        let big = try compressedTextChunk(keyword: "prompt", byteCount: 30 * 1024 * 1024)
        let over = try compressedTextChunk(keyword: "parameters", byteCount: 4 * 1024 * 1024)
        let url = try makeRawPNG(named: "over_budget.png", chunks: [
            ("IHDR", validIHDR()), ("zTXt", big), ("zTXt", over), ("tEXt", Data("Description\u{0}Job ID: 1".utf8))
        ])

        let parsed = PNGChunkParser.parse(from: url)

        XCTAssertTrue(parsed.textBudgetExhausted)
        XCTAssertEqual(parsed.textChunks.keys.sorted(), ["prompt"])
        XCTAssertEqual(parsed.width, 1)
    }

    func testLatin1TextIsChargedInRetainedBytes() throws {
        // 20 MiB of Latin-1 "é" fits the byte limit but becomes 40 MiB of UTF-8 as a string.
        var body = Data("parameters".utf8)
        body.append(contentsOf: [0, 0])
        body.append(try zlibCompressed(Data(repeating: 0xE9, count: 20 * 1024 * 1024)))
        let url = try makeRawPNG(named: "latin1.png", chunks: [("IHDR", validIHDR()), ("zTXt", body)])

        let parsed = PNGChunkParser.parse(from: url)

        XCTAssertTrue(parsed.textBudgetExhausted)
        let retained = parsed.textChunks.values.reduce(0) { $0 + $1.utf8.count }
        XCTAssertLessThanOrEqual(retained, PNGChunkParser.maxTotalTextBytes)
    }

    func testTextChunkCountIsBounded() throws {
        var chunks: [(String, Data)] = [("IHDR", validIHDR())]
        for index in 0..<PNGChunkParser.maxTextChunks {
            chunks.append(("tEXt", Data("filler\(index)\u{0}x".utf8)))
        }
        chunks.append(("tEXt", Data("parameters\u{0}late\nSteps: 3".utf8)))
        let url = try makeRawPNG(named: "many_chunks.png", chunks: chunks)

        let parsed = PNGChunkParser.parse(from: url)

        XCTAssertTrue(parsed.textBudgetExhausted)
        XCTAssertTrue(parsed.textChunks.isEmpty)
    }

    func testOrdinaryMetadataStaysWithinBudget() throws {
        let url = try makeRawPNG(named: "ordinary.png", chunks: [
            ("IHDR", validIHDR()),
            ("tEXt", Data("parameters\u{0}a cat\nSteps: 20, Seed: 5".utf8)),
            ("tEXt", Data("example-tool\u{0}{}".utf8)),
            ("tEXt", Data("Software\u{0}Example Tool".utf8))
        ])

        let parsed = PNGChunkParser.parse(from: url, additionalKeywords: ["example-tool"])
        let result = MediaMetadataExtractor.extract(
            from: url, provenanceMarkers: [PNGProvenanceMarker(keyword: "example-tool", platform: "Example Tool")]
        )

        XCTAssertFalse(parsed.textBudgetExhausted)
        XCTAssertEqual(parsed.textChunks.keys.sorted(), ["example-tool", "parameters"])
        XCTAssertEqual(result.sourcePlatform, "Example Tool")
        XCTAssertEqual(result.steps, 20)
    }

    // MARK: - Helpers

    /// A zTXt body whose text inflates to `byteCount` spaces.
    private func compressedTextChunk(keyword: String, byteCount: Int) throws -> Data {
        var body = Data(keyword.utf8)
        body.append(contentsOf: [0, 0])  // NUL after keyword, compression method: deflate
        body.append(try zlibCompressed(Data(repeating: 0x20, count: byteCount)))
        return body
    }

    /// Another zTXt body with the same compressed text under a different keyword.
    private func compressedTextChunk(keyword: String, reusing body: Data) throws -> Data {
        guard let nul = body.firstIndex(of: 0) else { throw TestError.invalidPNG }
        var renamed = Data(keyword.utf8)
        renamed.append(body[nul...])
        return renamed
    }
}
