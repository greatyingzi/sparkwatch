import Foundation

/// A trailing mean over a time window.
///
/// Why: GPU power on a tensor-parallel pair oscillates hard. Measured on this
/// pair under real load — 50 samples, ~1.3 s apart — the raw reading swung
/// 50.7–84.6 W and 43.3–84.8 W across the two boxes, with adjacent samples
/// jumping 9–10 W on average and 34–38 W at worst. That is not a fault: each
/// rank alternates between a compute burst and a wait on its peer link. The
/// reading is honest and still useless to look at.
///
/// The window has to be longer than that oscillation period to cancel it. The
/// same measurement, filtered:
///
/// | window | residual jump (avg) |
/// | --- | --- |
/// | ~4 s (3 samples) | 4.07 W — resonates with the cycle, little help |
/// | ~6.5 s (5) | 2.52 W |
/// | ~10 s (8) | 1.71 W |
/// | ~13 s (10) | 1.06 W — flattest, but visibly laggy |
///
/// So the window is expressed in **seconds**, and the raw sample is kept
/// alongside the mean: a smoothed number that cannot be checked against the
/// instant it came from is just a nicer-looking lie.
public struct TimeWindowMean: Sendable {
    /// Window length in seconds. Zero (or less) means "no smoothing".
    public var windowSeconds: Double
    private var samples: [(t: Double, value: Double)] = []   // tuples: not Equatable, and nothing compares smoothers

    public init(windowSeconds: Double) {
        self.windowSeconds = windowSeconds
    }

    public var isEnabled: Bool { windowSeconds > 0 }

    public mutating func add(_ value: Double, at time: Double) {
        guard isEnabled else { return }
        samples.append((t: time, value: value))
        // Drop anything older than the window (keeping one sample of slack so a
        // single stalled update does not empty the buffer and flash a mean).
        let cutoff = time - windowSeconds
        if let firstInside = samples.firstIndex(where: { $0.t >= cutoff }) {
            samples.removeFirst(max(0, firstInside))
        }
        if samples.count > 512 { samples.removeFirst(samples.count - 512) }
    }

    /// Mean over the window, or nil when nothing has been collected yet.
    public var mean: Double? {
        guard isEnabled, !samples.isEmpty else { return nil }
        return samples.reduce(0) { $0 + $1.value } / Double(samples.count)
    }

    public mutating func reset() { samples.removeAll() }
}
