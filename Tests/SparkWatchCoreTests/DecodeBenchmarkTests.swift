import Foundation
import Testing
@testable import SparkWatchCore

@Suite("解码基准")
struct DecodeBenchmarkTests {
    // MARK: - SSE fixtures
    //
    // The real wire format, copied from an OpenAI-compatible stream: each token
    // is one `data: {...}` line, `data: [DONE]` ends it, usage rides the last
    // data line. `now` below maps line index -> arrival seconds, so a token's
    // stamped time is just its line number unless a fixture says otherwise.

    private func content(_ text: String) -> String {
        "data: {\"choices\":[{\"delta\":{\"content\":\"\(text)\"}}]}"
    }

    private func reasoning(_ text: String) -> String {
        "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"\(text)\"}}]}"
    }

    // MARK: - parseSSE

    @Test func parseThreeContentChunks() {
        let lines = [content("Hello"), content(" world"), content("!")]
        let parsed = DecodeBenchmark.parseSSE(lines, startedAt: 0) { Double($0) * 0.5 }
        #expect(parsed.tokenTimes == [0.0, 0.5, 1.0])
        #expect(parsed.completionTokens == nil)
        #expect(parsed.finished == false)
        #expect(parsed.errorText == nil)
    }

    @Test func parseReasoningContentCountsAsAToken() {
        let lines = [reasoning("step one"), content("answer")]
        let parsed = DecodeBenchmark.parseSSE(lines, startedAt: 0) { Double($0) }
        #expect(parsed.tokenTimes == [0.0, 1.0])
    }

    @Test func parseStopsAfterDone() {
        let lines = [content("a"), "data: [DONE]", content("ignored")]
        let parsed = DecodeBenchmark.parseSSE(lines, startedAt: 0) { Double($0) }
        #expect(parsed.tokenTimes == [0.0])
        #expect(parsed.finished == true)
    }

    @Test func parseCapturesUsageCompletionTokens() {
        let lines = [
            content("a"),
            content("b"),
            "data: {\"choices\":[],\"usage\":{\"completion_tokens\":7}}",
        ]
        let parsed = DecodeBenchmark.parseSSE(lines, startedAt: 0) { Double($0) }
        #expect(parsed.completionTokens == 7)
        #expect(parsed.tokenTimes.count == 2)   // usage chunk is not a token
    }

    @Test func parseIgnoresMalformedAndNonDataLines() {
        let lines = [
            ": keep-alive comment",
            "event: message",
            content("a"),
            "data: {not valid json",
            "data: {\"choices\":[{\"delta\":{\"content\":\"b\"}}]}",
        ]
        let parsed = DecodeBenchmark.parseSSE(lines, startedAt: 0) { Double($0) }
        // Only lines 2 and 4 carry tokens; the malformed line neither crashes
        // nor pollutes the timeline.
        #expect(parsed.tokenTimes == [2.0, 4.0])
        #expect(parsed.errorText == nil)
    }

    @Test func parseEmptyDeltaIsNotAToken() {
        let lines = [
            "data: {\"choices\":[{\"delta\":{\"content\":\"\"}}]}",
            "data: {\"choices\":[{\"delta\":{}}]}",
            content("x"),
        ]
        let parsed = DecodeBenchmark.parseSSE(lines, startedAt: 0) { Double($0) }
        #expect(parsed.tokenTimes == [2.0])
    }

    @Test func parseSurfacesStreamedError() {
        let lines = ["data: {\"error\":{\"message\":\"engine overloaded\"}}"]
        let parsed = DecodeBenchmark.parseSSE(lines, startedAt: 0) { Double($0) }
        #expect(parsed.errorText == "engine overloaded")
        #expect(parsed.tokenTimes.isEmpty)
    }

    @Test func parseTimesAreRelativeToStartedAt() {
        let lines = [content("a"), content("b")]
        // now() returns absolute seconds; startedAt is subtracted.
        let parsed = DecodeBenchmark.parseSSE(lines, startedAt: 100) { 100 + Double($0) * 0.25 }
        #expect(parsed.tokenTimes == [0.0, 0.25])
    }

    // MARK: - decodeRate

    @Test func rateForTenTokensSpanningOneSecond() {
        let times = (0..<10).map { Double($0) / 9.0 }   // 0.0 ... 1.0
        let rate = DecodeBenchmark.decodeRate(tokenTimes: times, completionTokens: nil)
        #expect(rate != nil)
        #expect(abs((rate ?? 0) - 9.0) < 1e-9)
    }

    @Test func rateNilForSingleToken() {
        #expect(DecodeBenchmark.decodeRate(tokenTimes: [1.0], completionTokens: nil) == nil)
    }

    @Test func rateNilForEmptyTimes() {
        #expect(DecodeBenchmark.decodeRate(tokenTimes: [], completionTokens: nil) == nil)
        // Even with a token count, no timestamps means no measurable rate.
        #expect(DecodeBenchmark.decodeRate(tokenTimes: [], completionTokens: 50) == nil)
    }

    @Test func rateUsesEarliestAndLatestNotFirstAndLast() {
        // Out of order: first entry is not the earliest, last entry is not the
        // latest. Must span 0.0 -> 1.0 = 1.0s, not 0.5 -> 0.25.
        let times = [0.5, 0.0, 1.0, 0.25]
        let rate = DecodeBenchmark.decodeRate(tokenTimes: times, completionTokens: nil)
        #expect(rate != nil)
        #expect(abs((rate ?? 0) - 3.0) < 1e-9)   // (4-1)/1.0
    }

    @Test func ratePrefersCompletionTokensOverChunkCount() {
        // Engine streamed reasoning separately: only 3 stamped times, but it
        // reports 11 completion tokens. Rate must use 11.
        let times = [0.5, 2.5, 1.0]
        let rate = DecodeBenchmark.decodeRate(tokenTimes: times, completionTokens: 11)
        #expect(rate != nil)
        #expect(abs((rate ?? 0) - 5.0) < 1e-9)   // (11-1)/(2.5-0.5)
    }

    @Test func rateNilWhenSpanIsZero() {
        #expect(DecodeBenchmark.decodeRate(tokenTimes: [2.0, 2.0], completionTokens: nil) == nil)
    }

    // MARK: - summarise

    private func okStream(tps: Double, tokens: Int, ttft: Double) -> DecodeBenchmark.StreamResult {
        DecodeBenchmark.StreamResult(
            ok: true,
            decodeTPS: tps,
            ttftMs: ttft,
            completionTokens: tokens,
            totalMs: 500
        )
    }

    private func failedStream(_ message: String) -> DecodeBenchmark.StreamResult {
        DecodeBenchmark.StreamResult(ok: false, error: message)
    }

    @Test func summariseCountsOnlySuccessfulStreams() {
        let streams = [
            okStream(tps: 900, tokens: 101, ttft: 100),
            failedStream("HTTP 500"),
            okStream(tps: 700, tokens: 51, ttft: 200),
            okStream(tps: 1100, tokens: 201, ttft: 300),
            failedStream("timeout"),
        ]
        let wave = DecodeBenchmark.summarise(concurrency: 5, streams: streams, durationMs: 1000)

        #expect(wave.meanDecodeTPS != nil)
        #expect(abs((wave.meanDecodeTPS ?? 0) - 900.0) < 1e-9)   // (900+700+1100)/3
        #expect(abs((wave.medianDecodeTPS ?? 0) - 900.0) < 1e-9) // sorted [700,900,1100]
        #expect(abs((wave.maxDecodeTPS ?? 0) - 1100.0) < 1e-9)
        #expect(abs((wave.meanTtftMs ?? 0) - 200.0) < 1e-9)      // (100+200+300)/3
        #expect(wave.error == nil)

        // totalDecodeTokens = (101-1)+(51-1)+(201-1) = 350
        #expect(wave.totalDecodeTokens == 350)
        // aggregate = 350 tokens / 1.0s
        #expect(abs((wave.aggregateDecodeTPS ?? 0) - 350.0) < 1e-9)
    }

    @Test func summariseMedianAveragesTwoMiddleRates() {
        let streams = [
            okStream(tps: 100, tokens: 11, ttft: 10),
            okStream(tps: 300, tokens: 11, ttft: 10),
        ]
        let wave = DecodeBenchmark.summarise(concurrency: 2, streams: streams, durationMs: 500)
        #expect(abs((wave.medianDecodeTPS ?? 0) - 200.0) < 1e-9)
    }

    @Test func summariseAggregateUsesTotalTokensOverWallClock() {
        // 11 + 5 tokens => (11-1)+(5-1) = 14 decode tokens; wave took 2 s.
        let streams = [okStream(tps: 50, tokens: 11, ttft: 5), okStream(tps: 40, tokens: 5, ttft: 5)]
        let wave = DecodeBenchmark.summarise(concurrency: 2, streams: streams, durationMs: 2000)
        #expect(wave.totalDecodeTokens == 14)
        #expect(abs((wave.aggregateDecodeTPS ?? 0) - 7.0) < 1e-9)
    }

    @Test func summariseAllFailedHasError() {
        let streams = [failedStream("HTTP 500"), failedStream("connection refused")]
        let wave = DecodeBenchmark.summarise(concurrency: 2, streams: streams, durationMs: 1000)
        #expect(wave.error != nil)
        #expect(wave.meanDecodeTPS == nil)
        #expect(wave.medianDecodeTPS == nil)
        #expect(wave.maxDecodeTPS == nil)
        #expect(wave.totalDecodeTokens == 0)
    }

    @Test func summariseIgnoresNonPositiveTokenDeltas() {
        // completionTokens 0 or 1 contributes nothing to decode tokens.
        let streams = [
            okStream(tps: 10, tokens: 0, ttft: 1),
            okStream(tps: 10, tokens: 1, ttft: 1),
            okStream(tps: 10, tokens: 31, ttft: 1),
        ]
        let wave = DecodeBenchmark.summarise(concurrency: 3, streams: streams, durationMs: 1000)
        #expect(wave.totalDecodeTokens == 30)   // only 31-1
    }

    // MARK: - Options

    @Test func optionsFiltersIllegalConcurrencyKeepingOrderAndDeduping() {
        let options = DecodeBenchmark.Options(
            baseURL: "http://spark-a:18000",
            concurrencyLevels: [4, 7, 2, 2, 1, 0, -3, 8]
        )
        #expect(options.concurrencyLevels == [4, 2, 1, 8])
    }

    @Test func optionsEmptyOrAllIllegalConcurrencyFallsBack() {
        let empty = DecodeBenchmark.Options(baseURL: "x", concurrencyLevels: [])
        #expect(empty.concurrencyLevels == [1, 2, 4, 8])
        let illegal = DecodeBenchmark.Options(baseURL: "x", concurrencyLevels: [7, 9, 11, 100])
        #expect(illegal.concurrencyLevels == [1, 2, 4, 8])
    }

    @Test func optionsClampsMaxTokensIntoSupportedWindow() {
        #expect(DecodeBenchmark.Options(baseURL: "x", maxTokens: 10).maxTokens == 64)
        #expect(DecodeBenchmark.Options(baseURL: "x", maxTokens: 999_999).maxTokens == 2048)
        #expect(DecodeBenchmark.Options(baseURL: "x", maxTokens: 400).maxTokens == 400)
        #expect(DecodeBenchmark.Options(baseURL: "x", maxTokens: 64).maxTokens == 64)
        #expect(DecodeBenchmark.Options(baseURL: "x", maxTokens: 2048).maxTokens == 2048)
    }

    @Test func optionsDefaults() {
        let options = DecodeBenchmark.Options(baseURL: "http://host:18000")
        #expect(options.model == nil)
        #expect(options.apiKey == nil)
        #expect(options.maxTokens == 400)
        #expect(options.concurrencyLevels == [1, 2, 4, 8])
        #expect(options.timeoutSeconds == 360)
        #expect(options.warmup == true)
        #expect(options.prompt == DecodeBenchmark.defaultPrompt)
    }

    @Test func allowedConcurrencyIsTheDocumentedLadder() {
        #expect(DecodeBenchmark.allowedConcurrency == [1, 2, 3, 4, 5, 6, 8, 10, 12, 16, 24, 32])
    }

    @Test func defaultPromptIsTheRightLengthAndShape() {
        let words = DecodeBenchmark.defaultPrompt.split(whereSeparator: { $0 == " " || $0.isNewline })
        #expect(words.count >= 60)
        #expect(words.count <= 120)
        #expect(DecodeBenchmark.defaultPrompt.lowercased().contains("markdown"))
        #expect(DecodeBenchmark.defaultPrompt.lowercased().contains("reasoning"))
    }
}
