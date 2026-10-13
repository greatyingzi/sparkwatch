import Foundation
import Testing
@testable import SparkWatchCore

@Suite("功耗滑动窗口")
struct PowerSmoothingTests {
    /// The real signal, copied verbatim: 50 consecutive `power.draw` samples from
    /// spark-00 under load, ~1.3 s apart. Mean 74.9 W, but it swings 50.7-84.6 W
    /// as each tensor-parallel rank alternates a burst with a wait on its peer.
    private let oscillation: [Double] = [
        83, 76, 76, 83, 83, 58, 54, 83, 76, 82, 82, 67, 84, 83, 83, 83, 62, 59, 62, 83, 75,
        57, 83, 83, 84, 84, 83, 77, 85, 84, 51, 59, 57, 75, 83, 84, 81, 82, 60, 82, 80,
        55, 55, 73, 85, 84, 64, 83, 83, 69,
    ]

    @Test func smoothsTheMeasuredOscillation() {
        var smoother = TimeWindowMean(windowSeconds: 10)     // ~8 samples at 1.3 s
        var series: [Double] = []
        for (index, value) in oscillation.enumerated() {
            smoother.add(value, at: Double(index) * 1.3)
            series.append(smoother.mean ?? 0)
        }
        // Measured: the raw series jumps 9.4 W between adjacent samples on
        // average; a 10 s window leaves ~1.7 W.
        let rawJumps = zip(oscillation, oscillation.dropFirst()).map { abs($1 - $0) }
        let smoothJumps = zip(series, series.dropFirst()).map { abs($1 - $0) }
        let rawAvg = rawJumps.reduce(0, +) / Double(rawJumps.count)
        let smoothAvg = smoothJumps.reduce(0, +) / Double(smoothJumps.count)
        #expect(abs(rawAvg - 9.4) < 0.5)         // the measured flicker
        #expect(smoothAvg < 2.5)                 // the measured residual

        // And it sits near the true mean (74.9 W here) rather than drifting to
        // one of the two levels the raw signal bounces between.
        #expect(abs((series.last ?? 0) - 74.9) < 6)
    }

    /// A step change must arrive, just late — smoothing is not an excuse to
    /// freeze the display.
    @Test func aStepArrivesWithinTheWindow() {
        var smoother = TimeWindowMean(windowSeconds: 5)
        for index in 0..<40 { smoother.add(10, at: Double(index)) }      // settled at 10
        #expect(abs((smoother.mean ?? 0) - 10) < 0.01)
        for index in 40..<80 { smoother.add(90, at: Double(index)) }     // step to 90
        // After a full window of the new value the mean is the new value.
        #expect(abs((smoother.mean ?? 0) - 90) < 0.01)
    }

    @Test func samplesExpireOutOfTheWindow() {
        var smoother = TimeWindowMean(windowSeconds: 4)
        smoother.add(100, at: 0)
        smoother.add(100, at: 1)
        #expect(smoother.mean == 100)
        // T+10: both are long gone.
        smoother.add(20, at: 10)
        #expect(abs((smoother.mean ?? 0) - 20) < 0.01)
    }

    @Test func zeroWindowIsAPassthrough() {
        var smoother = TimeWindowMean(windowSeconds: 0)
        smoother.add(42, at: 0)
        #expect(smoother.mean == nil)          // disabled: caller uses the raw value
        #expect(smoother.isEnabled == false)
    }

    @Test func emptyBufferHasNoMean() {
        let smoother = TimeWindowMean(windowSeconds: 8)
        #expect(smoother.mean == nil)
    }
}
