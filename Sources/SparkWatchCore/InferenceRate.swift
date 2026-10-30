import Foundation

// Which number the display is allowed to call "decode speed", and why.
//
// The rule used to be one line — Δgeneration_tokens_total ÷ Δwall — and on the
// live TensorFold deployment (2026-10-30) that line was wrong in both directions:
//
//   * `tensorfold:generation_tokens_total` is published at **request boundaries**.
//     Measured: frozen at 2 363 261 for the whole 11.2 s of a request (29 polls,
//     1 saw growth), then +400 in one step. So the rate read 0 for the entire
//     request and ~200 tok/s at the moment it finished.
//   * the engine already answers both questions live — `/health` →
//     `live.decode_tokens_per_second` (25 single-stream, 50 with two) and
//     `live.prefill_tokens_per_second` (862–1006 during a prefill) — and
//     `/metrics` carries `tensorfold:generation_tokens_running`, a gauge whose
//     derivative is the same number (measured +50.6 tok/s over 11.1 s).
//
// So the sources are ranked, and the ranking is data, not preference:
//
//   health  the engine's own instantaneous rate — free, smoothed, and the only
//           one that exists mid-request on a boundary-published engine.
//   gauge   Δ(in-flight token gauge) ÷ Δwall — live, aggregate across streams.
//           Only when the gauge did not decrease: it drops to 0 when a stream
//           finishes, and a delta across that reset is not a rate.
//   engine  Δtokens ÷ Δdecode_seconds at the moment requests finish — honest but
//           not live: it is the aggregate speed of the batch that just ended.
//   counter Δgeneration_tokens_total ÷ Δwall — the historical default; kept for
//           engines that really do publish live totals (vLLM, SGLang).
//
// And one negative rule that matters as much as the ranking: when a live source
// exists and the counter jumped *because a request ended*, that jump must not be
// divided by the sample window. That is the 200 tok/s spike.

/// The in-flight token gauge turned into a rate.
///
/// `tensorfold:generation_tokens_running` counts tokens produced by the
/// generations still running, summed over streams. It moves during a request and
/// resets when the last stream finishes, which is exactly the shape a live rate
/// needs — and exactly why a decrease has to be treated as "no reading" instead
/// of a negative rate.
public struct GaugeTokensRateTracker: Sendable {
    private var last: (at: Date, tokens: Double)?
    private var lastRateValue: Double?
    private var lastRateAt: Date?

    public init() {}

    public mutating func update(tokens: Double?, at now: Date = Date()) -> Double? {
        defer {
            if let tokens { last = (now, tokens) }
        }
        guard let tokens, let previous = last else { return nil }
        let seconds = now.timeIntervalSince(previous.at)
        guard seconds > 0.001 else { return nil }
        let delta = tokens - previous.tokens
        // A reset (or a stream leaving the batch) is not a slowdown: it is a
        // different generation. Drop the interval rather than report a negative.
        guard delta > 0 else { return nil }
        lastRateValue = delta / seconds
        lastRateAt = now
        return lastRateValue
    }

    /// Rate from the last interval where the gauge grew, and how old it is.
    public var lastRate: Double? { lastRateValue }

    public func age(now: Date = Date()) -> Double? {
        guard let lastRateAt else { return nil }
        return now.timeIntervalSince(lastRateAt)
    }
}

/// What the collector should put on screen this cycle.
public struct RateResolution: Sendable, Equatable {
    public var tps: Double?
    /// Which source answered: `health` / `gauge` / `engine` / `counter` / `none`.
    /// Carried into `SPARKWATCH_TRACE` so "why is this number late" is answerable
    /// from a log instead of an argument.
    public var source: String
    /// Requests were in flight but the counter did not move (and no live source
    /// answered): the engine publishes totals only at boundaries. The UI says so
    /// instead of showing a stale green figure.
    public var counterStale: Bool

    public init(tps: Double?, source: String, counterStale: Bool) {
        self.tps = tps
        self.source = source
        self.counterStale = counterStale
    }
}

public enum InferenceRateResolver {
    /// - Parameters:
    ///   - nativeRate: engine-reported instantaneous decode rate (`/health`).
    ///   - nativeBusy: the engine reports work in flight *this* cycle. A native
    ///     rate without work is the engine's own EMA still coasting for a second
    ///     or two after the last stream, and showing it as live is the same lie as
    ///     a frozen counter.
    ///   - gaugeRate: Δin-flight-token gauge ÷ Δwall.
    ///   - wallRate: Δgeneration_tokens_total ÷ Δwall, already vetted against idle
    ///     dilution by the caller (`SpeedDisplay.rateIsTrustworthy`).
    ///   - engineRate: Δtokens ÷ Δdecode_seconds, meaningful at a boundary.
    ///   - justFinished: the previous cycle had work and this one does not.
    ///   - hasLiveSource: this engine exposed a live source (native or gauge) at
    ///     any point in the run.
    public static func resolve(
        nativeRate: Double?,
        nativeBusy: Bool,
        gaugeRate: Double?,
        wallRate: Double?,
        engineRate: Double?,
        justFinished: Bool,
        hasLiveSource: Bool
    ) -> RateResolution {
        if let nativeRate, nativeBusy, nativeRate > 0.5, nativeRate.isFinite {
            return RateResolution(tps: nativeRate, source: "health", counterStale: false)
        }
        if let gaugeRate, gaugeRate > 0.5, gaugeRate.isFinite {
            return RateResolution(tps: gaugeRate, source: "gauge", counterStale: false)
        }
        if justFinished, hasLiveSource {
            // The counter jump belongs to the request that just ended, not to this
            // sampling window. Divide it by engine-time when the engine counts it.
            if let engineRate, engineRate > 0.5, engineRate.isFinite {
                return RateResolution(tps: engineRate, source: "engine", counterStale: false)
            }
            return RateResolution(tps: nil, source: "boundary", counterStale: false)
        }
        if let wallRate, wallRate > 0.5, wallRate.isFinite {
            return RateResolution(tps: wallRate, source: "counter", counterStale: false)
        }
        return RateResolution(tps: nil, source: "none", counterStale: nativeBusy)
    }

    /// Prefill has the same hierarchy, one level simpler: the engine's live figure
    /// is the truth while it is non-zero, and the tracked boundary figure is only
    /// a fallback for engines that account prefill time themselves.
    public static func prefill(native: Double?, tracked: Double?) -> Double? {
        if let native, native > 0.5, native.isFinite { return native }
        return tracked
    }
}
