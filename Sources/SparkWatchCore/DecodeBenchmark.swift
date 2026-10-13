import Foundation

// A pure-HTTP decode benchmark. No SSH, no installs: it drives an
// OpenAI-compatible endpoint (TensorFold on :18000, vLLM / SGLang / llama.cpp
// all speak the same wire format) and measures *controlled* decode speed, which
// is more trustworthy than the panel's live tok/s — the live number is a delta
// over whatever the engine happened to be doing, this is a fixed prompt run at
// a known concurrency.
//
// Protocol, implemented verbatim below:
//
//   POST {baseURL}/v1/chat/completions
//   {
//     "model": <model?>,                       // omitted entirely when nil
//     "messages": [{"role":"user","content": <prompt>}],
//     "max_tokens": <maxTokens>, "temperature": 0, "top_p": 1,
//     "stream": true, "stream_options": {"include_usage": true}
//   }
//   Authorization: Bearer <apiKey>             // only when apiKey is set
//
// SSE parsing rules (see `parseSSE`): only `data: ` lines count, `data: [DONE]`
// ends the stream, and every chunk whose `choices[0].delta.content` *or*
// `delta.reasoning_content` is non-empty stamps one token arrival. If the engine
// reports `usage.completion_tokens` we keep it and prefer it over the chunk
// count — some engines stream reasoning and content in separate chunks and
// chunk-counting undercounts; the usage field is authoritative.
//
// Two hard rules learned operating this fleet:
//   1. NEVER use the shared/system URLSession. FlClash routes 100.x tailnet and
//      LAN addresses through the proxy, turning every request into a 502 while
//      `curl` (which honours NO_PROXY) keeps working. We always go through
//      `HTTP.noProxySession`.
//   2. Whole-wave timeout + warmup: a cold engine pays JIT / draft-model warmup
//      on its first request, so we run one throwaway request before each
//      concurrency level and never let that cost land on the score.

public struct DecodeBenchmark: Sendable {
    public init() {}

    // MARK: Public surface

    public static let allowedConcurrency: [Int] = [1, 2, 3, 4, 5, 6, 8, 10, 12, 16, 24, 32]

    /// A fixed English task that asks for direct output with no reasoning, no
    /// markdown and no headings — so the measured tokens are all decode, no
    /// visible chain-of-thought, and long enough (~83 words of instruction, asks
    /// for ~300 words of output) to give a stable rate without hitting
    /// `max_tokens` too early.
    public static let defaultPrompt: String = """
    Write a plain factual explanation of how a refrigerator keeps food cold. \
    Explain the compressor, the expansion valve, and the evaporator coil in \
    simple terms. Output only the finished explanation as one continuous \
    paragraph. Do not show your reasoning, do not think step by step, do not \
    add a title, do not use markdown, bullet points, or headings. Never mention \
    these instructions. Begin immediately with the first sentence of the answer \
    and keep going until you reach roughly three hundred words, then stop.
    """

    public struct Options: Sendable {
        public var baseURL: String
        public var model: String?
        public var apiKey: String?
        public var maxTokens: Int
        public var concurrencyLevels: [Int]
        public var prompt: String
        public var timeoutSeconds: TimeInterval
        public var warmup: Bool

        public init(
            baseURL: String,
            model: String? = nil,
            apiKey: String? = nil,
            maxTokens: Int = 400,
            concurrencyLevels: [Int] = [1, 2, 4, 8],
            prompt: String = DecodeBenchmark.defaultPrompt,
            timeoutSeconds: TimeInterval = 360,
            warmup: Bool = true
        ) {
            self.baseURL = baseURL
            self.model = model
            self.apiKey = apiKey
            // Clamp into the supported window rather than reject: a caller who
            // asks for 30 (too short to be a decode benchmark) or 8000 (would
            // blow the wave budget) still gets a sane run.
            self.maxTokens = Swift.max(64, Swift.min(2048, maxTokens))
            self.prompt = prompt
            self.timeoutSeconds = timeoutSeconds
            self.warmup = warmup

            // Only concurrency levels the engine can be trusted to schedule
            // belong here. Filter to the allow-list, keep first-seen order,
            // drop duplicates, and fall back to the default ladder if nothing
            // survives.
            var seen = Set<Int>()
            var levels: [Int] = []
            for level in concurrencyLevels where DecodeBenchmark.allowedConcurrency.contains(level) {
                if seen.insert(level).inserted { levels.append(level) }
            }
            self.concurrencyLevels = levels.isEmpty ? [1, 2, 4, 8] : levels
        }
    }

    /// One streamed request. `decodeTPS` is per-stream decode speed; the honest
    /// per-stream number, not a fleet throughput.
    public struct StreamResult: Sendable, Equatable {
        public var ok: Bool
        /// `(completionTokens − 1) / (last token time − first token time)`.
        public var decodeTPS: Double?
        /// First-token latency in ms (time to the first counted token).
        public var ttftMs: Double?
        public var completionTokens: Int?
        public var totalMs: Double?
        public var error: String?

        public init(
            ok: Bool,
            decodeTPS: Double? = nil,
            ttftMs: Double? = nil,
            completionTokens: Int? = nil,
            totalMs: Double? = nil,
            error: String? = nil
        ) {
            self.ok = ok
            self.decodeTPS = decodeTPS
            self.ttftMs = ttftMs
            self.completionTokens = completionTokens
            self.totalMs = totalMs
            self.error = error
        }
    }

    /// One concurrency level: `concurrency` streams fired together.
    public struct WaveResult: Sendable, Equatable {
        public var concurrency: Int
        public var streams: [StreamResult]
        public var meanDecodeTPS: Double?
        public var medianDecodeTPS: Double?
        public var maxDecodeTPS: Double?
        /// The real *throughput*: total decode tokens across the wave ÷ the
        /// wall-clock length of the wave. This is what falls off a cliff as
        /// concurrency climbs; per-stream `meanDecodeTPS` is what each request
        /// felt.
        public var aggregateDecodeTPS: Double?
        public var meanTtftMs: Double?
        public var totalDecodeTokens: Int
        public var durationMs: Double
        public var error: String?

        public init(
            concurrency: Int,
            streams: [StreamResult],
            meanDecodeTPS: Double? = nil,
            medianDecodeTPS: Double? = nil,
            maxDecodeTPS: Double? = nil,
            aggregateDecodeTPS: Double? = nil,
            meanTtftMs: Double? = nil,
            totalDecodeTokens: Int = 0,
            durationMs: Double = 0,
            error: String? = nil
        ) {
            self.concurrency = concurrency
            self.streams = streams
            self.meanDecodeTPS = meanDecodeTPS
            self.medianDecodeTPS = medianDecodeTPS
            self.maxDecodeTPS = maxDecodeTPS
            self.aggregateDecodeTPS = aggregateDecodeTPS
            self.meanTtftMs = meanTtftMs
            self.totalDecodeTokens = totalDecodeTokens
            self.durationMs = durationMs
            self.error = error
        }
    }

    /// Mid-run snapshot. `finishedWaves` is everything completed before the
    /// current wave, so a UI can render the curve as it fills in.
    public struct Progress: Sendable {
        public var waveIndex: Int
        public var waveCount: Int
        public var concurrency: Int
        public var finishedStreams: Int
        public var finishedWaves: [WaveResult]

        public init(
            waveIndex: Int,
            waveCount: Int,
            concurrency: Int,
            finishedStreams: Int,
            finishedWaves: [WaveResult]
        ) {
            self.waveIndex = waveIndex
            self.waveCount = waveCount
            self.concurrency = concurrency
            self.finishedStreams = finishedStreams
            self.finishedWaves = finishedWaves
        }
    }

    // MARK: Orchestration

    /// Run every concurrency level in order — one full wave before the next —
    /// and return the wave results. `onProgress` fires as each stream inside the
    /// current wave finishes; `onWave` fires once a wave is complete. Both are
    /// `@Sendable` because they are invoked off the main actor.
    public static func run(
        _ options: Options,
        onProgress: (@Sendable (Progress) -> Void)? = nil,
        onWave: (@Sendable (WaveResult) -> Void)? = nil
    ) async -> [WaveResult] {
        let session = HTTP.noProxySession(timeout: options.timeoutSeconds)
        var waves: [WaveResult] = []
        let levels = options.concurrencyLevels
        for (waveIndex, concurrency) in levels.enumerated() {
            let wave = await runWave(
                options: options,
                concurrency: concurrency,
                session: session,
                waveIndex: waveIndex,
                waveCount: levels.count,
                previousWaves: waves,
                onProgress: onProgress
            )
            waves.append(wave)
            onWave?(wave)
        }
        return waves
    }

    private static func runWave(
        options: Options,
        concurrency: Int,
        session: URLSession,
        waveIndex: Int,
        waveCount: Int,
        previousWaves: [WaveResult],
        onProgress: (@Sendable (Progress) -> Void)?
    ) async -> WaveResult {
        // Warmup: one throwaway request so JIT / draft-model cold cost is paid
        // before the wave starts timing. Deliberately tiny (max_tokens 32).
        if options.warmup {
            _ = await streamOnce(options: options, maxTokens: 32, session: session)
        }

        let startedAt = Date().timeIntervalSince1970
        var streams = [StreamResult?](repeating: nil, count: concurrency)
        let counter = FinishedCounter()

        await withTaskGroup(of: StreamOutcome.self) { group in
            for index in 0..<concurrency {
                group.addTask {
                    StreamOutcome(
                        index: index,
                        result: await streamOnce(
                            options: options,
                            maxTokens: options.maxTokens,
                            session: session
                        ),
                        isTimeout: false
                    )
                }
            }
            // The deadline task. If it wins, every stream below is cancelled and
            // the holes are filled with a timeout error.
            group.addTask {
                try? await Task.sleep(for: .seconds(options.timeoutSeconds))
                return StreamOutcome(
                    index: -1,
                    result: StreamResult(ok: false, error: "单波超时 \(Int(options.timeoutSeconds))s"),
                    isTimeout: true
                )
            }

            var completed = 0
            for await outcome in group {
                if outcome.isTimeout {
                    group.cancelAll()
                    continue
                }
                streams[outcome.index] = outcome.result
                completed += 1
                counter.increment()
                onProgress?(
                    Progress(
                        waveIndex: waveIndex,
                        waveCount: waveCount,
                        concurrency: concurrency,
                        finishedStreams: counter.value,
                        finishedWaves: previousWaves
                    )
                )
                if completed == concurrency { group.cancelAll() }
            }
        }

        for index in 0..<concurrency where streams[index] == nil {
            streams[index] = StreamResult(ok: false, error: "单波超时 \(Int(options.timeoutSeconds))s")
        }

        let durationMs = (Date().timeIntervalSince1970 - startedAt) * 1000
        return summarise(
            concurrency: concurrency,
            streams: streams.compactMap { $0 },
            durationMs: durationMs
        )
    }

    // MARK: Single stream

    /// Fire one streamed request and turn it into a `StreamResult`. Never
    /// throws: any transport / HTTP / parse problem is reported through
    /// `error`, and `ok` is false.
    private static func streamOnce(
        options: Options,
        maxTokens: Int,
        session: URLSession
    ) async -> StreamResult {
        let start = Date().timeIntervalSince1970

        let base = options.baseURL.hasSuffix("/")
            ? String(options.baseURL.dropLast())
            : options.baseURL
        guard let url = URL(string: base + "/v1/chat/completions") else {
            return StreamResult(ok: false, error: "非法 baseURL: \(options.baseURL)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = options.timeoutSeconds
        if let apiKey = options.apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        var body: [String: Any] = [
            "messages": [["role": "user", "content": options.prompt]],
            "max_tokens": maxTokens,
            "temperature": 0,
            "top_p": 1,
            "stream": true,
            "stream_options": ["include_usage": true],
        ]
        // Omit `model` entirely when nil — some soft-proxies reject an explicit
        // null, and a single-model engine picks its default.
        if let model = options.model, !model.isEmpty { body["model"] = model }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        var lines: [String] = []
        var arrival: [TimeInterval] = []

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                return StreamResult(ok: false, totalMs: elapsedMs(since: start), error: "无 HTTP 响应")
            }
            guard http.statusCode == 200 else {
                var snippet = ""
                for try await line in bytes.lines {
                    snippet += line
                    if snippet.count > 200 { break }
                }
                return StreamResult(
                    ok: false,
                    totalMs: elapsedMs(since: start),
                    error: "HTTP \(http.statusCode): \(snippet.prefix(160))"
                )
            }
            for try await line in bytes.lines {
                if Task.isCancelled { break }
                lines.append(line)
                arrival.append(Date().timeIntervalSince1970)
            }
        } catch is CancellationError {
            return StreamResult(ok: false, totalMs: elapsedMs(since: start), error: "已取消")
        } catch {
            return StreamResult(
                ok: false,
                totalMs: elapsedMs(since: start),
                error: String(describing: error)
            )
        }

        // Line i's arrival time, clamped for safety.
        let now: (Int) -> TimeInterval = { index in
            guard !arrival.isEmpty else { return start }
            return arrival[Swift.max(0, Swift.min(index, arrival.count - 1))]
        }
        let parsed = parseSSE(lines, startedAt: start, now: now)

        let tokenTimes = parsed.tokenTimes
        let count = parsed.completionTokens ?? (tokenTimes.isEmpty ? nil : tokenTimes.count)
        let rate = decodeRate(tokenTimes: tokenTimes, completionTokens: parsed.completionTokens)
        let ttft = tokenTimes.min().map { $0 * 1000 }
        return StreamResult(
            ok: parsed.errorText == nil,
            decodeTPS: rate,
            ttftMs: ttft,
            completionTokens: count,
            totalMs: elapsedMs(since: start),
            error: parsed.errorText
        )
    }

    private static func elapsedMs(since start: TimeInterval) -> Double {
        (Date().timeIntervalSince1970 - start) * 1000
    }

    // MARK: Pure parsing + statistics (the testable core)

    /// Parse one SSE byte stream into token arrival times.
    ///
    /// `lines` is the stream split on newlines; `now(i)` returns the wall-clock
    /// arrival time (seconds) of line `i`; the returned token times are relative
    /// to `startedAt`. Rules:
    ///   - only `data: ...` lines are considered;
    ///   - `data: [DONE]` sets `finished` and ends parsing (nothing after counts);
    ///   - a chunk counts as one token when `choices[].delta.content` OR
    ///     `choices[].delta.reasoning_content` is non-empty;
    ///   - `usage.completion_tokens` is captured whenever present (authoritative);
    ///   - malformed / non-JSON data lines are skipped: no crash, no token stamp.
    public static func parseSSE(
        _ lines: [String],
        startedAt: TimeInterval,
        now: (Int) -> TimeInterval
    ) -> (tokenTimes: [Double], completionTokens: Int?, finished: Bool, errorText: String?) {
        var tokenTimes: [Double] = []
        var completionTokens: Int?
        var finished = false
        var errorText: String?

        for (index, rawLine) in lines.enumerated() {
            if finished { break }

            var line = rawLine
            if line.hasSuffix("\r") { line.removeLast() }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Field separator: only `data:` payloads carry content.
            guard trimmed.hasPrefix("data:") else { continue }
            var payload = String(trimmed.dropFirst("data:".count))
            if payload.hasPrefix(" ") { payload.removeFirst() }
            if payload == "[DONE]" {
                finished = true
                continue
            }

            guard let data = payload.data(using: .utf8),
                let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                continue  // malformed line: skip without poisoning the timeline
            }

            // OpenAI-style error envelope, if the engine streamed one.
            if errorText == nil, let error = root["error"] {
                if let object = error as? [String: Any], let message = object["message"] as? String {
                    errorText = message
                } else if let text = error as? String {
                    errorText = text
                } else {
                    errorText = "服务端返回错误"
                }
            }

            if let usage = root["usage"] as? [String: Any],
                let completions = (usage["completion_tokens"] as? NSNumber)?.intValue
            {
                completionTokens = completions
            }

            var hasToken = false
            if let choices = root["choices"] as? [[String: Any]] {
                for choice in choices {
                    guard let delta = choice["delta"] as? [String: Any] else { continue }
                    if let content = delta["content"] as? String, !content.isEmpty {
                        hasToken = true
                        break
                    }
                    if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
                        hasToken = true
                        break
                    }
                }
            }
            if hasToken {
                tokenTimes.append(now(index) - startedAt)
            }
        }

        return (tokenTimes, completionTokens, finished, errorText)
    }

    /// Decode tokens per second from one stream.
    ///
    /// `(tokenCount − 1) / (last − first)`, where the count prefers the engine's
    /// `completionTokens` (falling back to the number of stamped token times) and
    /// the span uses the **earliest and latest** stamps, not the first/last
    /// entries — a stalled or out-of-order stream must not be able to fake speed
    /// by putting the newest timestamp first. Returns nil when there are fewer
    /// than 2 tokens or the span is not positive.
    public static func decodeRate(tokenTimes: [Double], completionTokens: Int?) -> Double? {
        let count = completionTokens ?? tokenTimes.count
        guard count >= 2 else { return nil }
        guard let earliest = tokenTimes.min(), let latest = tokenTimes.max() else { return nil }
        let span = latest - earliest
        guard span > 0 else { return nil }
        return Double(count - 1) / span
    }

    /// Fold one wave's streams into the summary. mean/median/max and the mean
    /// TTFT consider only successful streams; `aggregateDecodeTPS` is the whole
    /// wave's decode tokens over the wave's wall-clock seconds; `error` is set
    /// only when nothing in the wave succeeded.
    public static func summarise(
        concurrency: Int,
        streams: [StreamResult],
        durationMs: Double
    ) -> WaveResult {
        let okStreams = streams.filter { $0.ok }
        let rates = okStreams.compactMap { $0.decodeTPS }

        let mean = rates.isEmpty ? nil : rates.reduce(0, +) / Double(rates.count)
        let maxRate = rates.max()
        let median: Double? = {
            guard !rates.isEmpty else { return nil }
            let sorted = rates.sorted()
            let middle = sorted.count / 2
            if sorted.count % 2 == 1 { return sorted[middle] }
            return (sorted[middle - 1] + sorted[middle]) / 2
        }()

        let ttfts = okStreams.compactMap { $0.ttftMs }
        let meanTtft = ttfts.isEmpty ? nil : ttfts.reduce(0, +) / Double(ttfts.count)

        // Decode tokens per stream = completionTokens − 1 (the first token is not
        // part of the decode interval); negatives contribute nothing.
        let totalTokens = streams.reduce(0) { running, stream in
            guard let completions = stream.completionTokens else { return running }
            return running + Swift.max(0, completions - 1)
        }

        let aggregate: Double? = durationMs > 0
            ? Double(totalTokens) / (durationMs / 1000)
            : nil

        let errorText: String? = okStreams.isEmpty
            ? (streams.first(where: { $0.error != nil })?.error ?? "全部流失败")
            : nil

        return WaveResult(
            concurrency: concurrency,
            streams: streams,
            meanDecodeTPS: mean,
            medianDecodeTPS: median,
            maxDecodeTPS: maxRate,
            aggregateDecodeTPS: aggregate,
            meanTtftMs: meanTtft,
            totalDecodeTokens: totalTokens,
            durationMs: durationMs,
            error: errorText
        )
    }
}

/// Task-group outcome so the deadline can be told apart from a stream.
private struct StreamOutcome: Sendable {
    var index: Int
    var result: DecodeBenchmark.StreamResult
    var isTimeout: Bool
}

/// Lock-protected completed-stream counter shared by a wave's concurrent tasks.
private final class FinishedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
