import Foundation
import Testing
@testable import SparkWatchCore

@Suite("推理探针节奏（快显慢隐的一半）")
struct InferenceCadenceTests {
    /// The complaint this exists for: at a fixed 5 s cadence the first rate after
    /// a request starts takes up to 5 s to appear, while the box is visibly busy.
    @Test func workingIsPolledFast() {
        #expect(InferenceCadence.interval(gpuUtil: 94, powerW: 60, engineBusy: false)
            == InferenceCadence.active)
        // Utilisation alone is enough — a memory-bound step can sip power.
        #expect(InferenceCadence.interval(gpuUtil: 30, powerW: 12, engineBusy: false)
            == InferenceCadence.active)
        // Power alone is enough too — the burst phase of a decode step.
        #expect(InferenceCadence.interval(gpuUtil: 3, powerW: 40, engineBusy: false)
            == InferenceCadence.active)
        // The engine's own report keeps it fast even when the GPU looks calm.
        #expect(InferenceCadence.interval(gpuUtil: 2, powerW: 12, engineBusy: true)
            == InferenceCadence.active)
    }

    /// Idle costs an SSH round trip per probe, so it backs off.
    @Test func idleBacksOff() {
        #expect(InferenceCadence.interval(gpuUtil: 0, powerW: 12, engineBusy: false)
            == InferenceCadence.quiet)
        #expect(InferenceCadence.interval(gpuUtil: nil, powerW: nil, engineBusy: false)
            == InferenceCadence.quiet)
        // Just above idle draw is not "working".
        #expect(InferenceCadence.interval(gpuUtil: 5, powerW: 14, engineBusy: false)
            == InferenceCadence.quiet)
    }

    /// Fast must stay faster than quiet, or the whole idea inverts.
    @Test func fastIsFasterThanQuiet() {
        #expect(InferenceCadence.active < InferenceCadence.quiet)
        #expect(InferenceCadence.active <= 2.5)
    }

    /// The two ends of the display are deliberately asymmetric, and this encodes
    /// the asymmetry as a test so a future tweak cannot quietly make them equal.
    @Test func showingIsFasterThanHiding() {
        // Appearance: as soon as a rate exists it is live, no dwell first.
        #expect(SpeedDisplay.state(rate: 50, age: 0) == .live)
        // Disappearance: a measured rate survives a brief gap…
        #expect(SpeedDisplay.state(rate: 50, age: 4, running: 0) == .live)
        // …and only then greys, well before it expires.
        #expect(SpeedDisplay.state(rate: 50, age: 8, running: 0) == .stopped)
        #expect(SpeedDisplay.state(rate: 50, age: 200, running: 0) == .hidden)
        #expect(SpeedDisplay.minLiveSeconds < SpeedDisplay.freshnessSeconds)
        #expect(SpeedDisplay.freshnessSeconds < SpeedDisplay.expirySeconds)
    }
}

@Suite("第一个速率的可信性（不被空转稀释）")
struct RateTrustworthinessTests {
    /// A wall-clock interval longer than the active cadence contains idle time,
    /// so the reading is diluted — drop it and let the next one be clean.
    @Test func aLongIntervalIsRejected() {
        #expect(!SpeedDisplay.rateIsTrustworthy(intervalSeconds: 6.4, activeCadence: 2))
        #expect(!SpeedDisplay.rateIsTrustworthy(intervalSeconds: 5.0, activeCadence: 2))
        #expect(SpeedDisplay.rateIsTrustworthy(intervalSeconds: 3.0, activeCadence: 2))
        #expect(SpeedDisplay.rateIsTrustworthy(intervalSeconds: 2.2, activeCadence: 2))
        #expect(SpeedDisplay.rateIsTrustworthy(intervalSeconds: nil, activeCadence: 2))
    }

    /// The engine's own decode clock is the whole point: with it, a reading taken
    /// across a six-second gap is still correct, because the denominator only
    /// counts time spent decoding. This is the live case that produced 7.5 tok/s
    /// for work running at 46.
    @Test func theEngineDecodeClockIsNotDiluted() {
        var tracker = EngineDecodeRateTracker()
        // First observation, after a long idle gap.
        #expect(tracker.update(generationTokens: 242_239, decodeSeconds: 5_000) == nil)
        // 6.4 s of wall time later, but only 1.05 s of that was decoding:
        // 48 tokens in 1.05 s is 45.7 tok/s, not 48/6.4 = 7.5.
        let rate = tracker.update(generationTokens: 242_287, decodeSeconds: 5_001.05)
        #expect(abs((rate ?? 0) - 45.7) < 0.5)
    }

    @Test func theEngineClockNeedsBothToAdvance() {
        var tracker = EngineDecodeRateTracker()
        _ = tracker.update(generationTokens: 100, decodeSeconds: 10)
        // No tokens produced: no rate, whatever the clock says.
        #expect(tracker.update(generationTokens: 100, decodeSeconds: 12) == nil)
        // Tokens but a frozen clock: dividing by zero growth is nonsense.
        #expect(tracker.update(generationTokens: 150, decodeSeconds: 10) == nil)
        // Both advance: a rate. (50 more tokens in 1 more decode second.)
        #expect(tracker.update(generationTokens: 200, decodeSeconds: 11) == 50)
    }

    @Test func enginesWithoutADecodeClockFallBackToWallTime() {
        // No decode-seconds counter at all (llama.cpp): the tracker says nothing…
        var tracker = EngineDecodeRateTracker()
        #expect(tracker.update(generationTokens: 100, decodeSeconds: nil) == nil)
        #expect(tracker.update(generationTokens: 200, decodeSeconds: nil) == nil)
        // …and the wall-clock tracker with the interval guard takes over.
        var wall = TokenRateTracker()
        let t0 = Date(timeIntervalSince1970: 5000)
        #expect(wall.update(generationTokens: 100, at: t0) == nil)
        #expect(wall.update(generationTokens: 200, at: t0.addingTimeInterval(2)) == 50)
    }
}
