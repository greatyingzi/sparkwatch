import Foundation

/// How a decode rate should be shown, given how old the measurement is.
///
/// The rate is a counter delta, so it is only *live* for as long as the counter
/// keeps growing: the probe runs every few seconds, and between the request
/// finishing and the next probe the last value is still around. Showing that in
/// the same bright green as a live rate is a lie of emphasis — the number is
/// true, but the claim "this is happening now" is not.
///
/// So there are three states, and the mapping is: bright while it is fresh, grey
/// once the counter has stopped moving (the user asked for exactly this — 变成灰色文字),
/// and gone once the reading is old enough to be history rather than status.
public enum SpeedDisplay {
    public enum State: Equatable {
        /// Measured within the freshness window: this is happening now.
        case live
        /// Measured, but the counter has stopped: show the number, greyed, so it
        /// reads as "last known" instead of "current".
        case stopped
        /// Nothing worth showing (never measured, or long past).
        case hidden
    }

    /// A rate older than this is no longer "now". Longer than one probe cycle
    /// (a few seconds) so a single slow probe does not flicker the colour.
    public static let freshnessSeconds: Double = 12
    /// Past this, the reading is history: the row goes quiet rather than
    /// displaying a number from minutes ago.
    public static let expirySeconds: Double = 120
    /// Minimum time to keep showing a rate as live after it was measured.
    ///
    /// Showing and hiding are deliberately asymmetric: news of work should arrive
    /// as soon as possible (the probe cadence does that), while the end of work
    /// should not flicker the display. A short gap between two requests, a slow
    /// probe, or one burst that produced few tokens must not blink the number
    /// grey — so the engine's "nothing running" is only believed once this much
    /// time has passed since the last measurement.
    public static let minLiveSeconds: Double = 6

    /// - Parameters:
    ///   - rate: last measured decode rate (tok/s), nil if never measured.
    ///   - age: seconds since that rate was measured. `nil` means "measured in
    ///     this cycle" (the collector has just computed it).
    ///   - running: requests the engine reports in flight, when it reports them.
    public static func state(rate: Double?, age: Double?, running: Double? = nil) -> State {
        guard let rate, rate > 0.5 else { return .hidden }
        let age = age ?? 0
        if age > expirySeconds { return .hidden }
        // The engine's "nothing running" is the earliest possible hint that work
        // ended — but it is applied with the dwell above, because the moment a
        // request ends is exactly when a new one may be about to start, and a
        // display that blinks on every gap is unreadable.
        if let running, running == 0, age >= minLiveSeconds { return .stopped }
        return age <= freshnessSeconds ? .live : .stopped
    }

    /// Whether the interval behind a freshly computed rate can be trusted.
    ///
    /// The rate is a delta between two probes, so an interval that began *before*
    /// the work did is part idle time: a request that starts 1 s into a 6 s idle
    /// interval would be reported at a fifth of its true speed, then jump. Rather
    /// than show a wrong number fast, the first such reading is dropped (the
    /// probe still re-baselines the counter) and the next one — a couple of
    /// seconds later, inside the busy period — is accurate.
    public static func rateIsTrustworthy(
        intervalSeconds: Double?,
        activeCadence: Double
    ) -> Bool {
        guard let intervalSeconds else { return true }     // first ever probe
        // An interval longer than one cadence has idle time in it. 1.5× leaves
        // room for scheduling jitter without admitting a gap that matters.
        return intervalSeconds <= activeCadence * 1.5
    }

    /// "▶47/s" plus, when the reading is no longer live, how long ago it was
    /// measured — a grey number with no context invites "is it stuck?".
    public static func text(rate: Double, age: Double?, stopped: Bool) -> String {
        let base = String(format: "▶%.0f/s", rate)
        guard stopped, let age, age >= 1 else { return base }
        let ago = age >= 60 ? String(format: "%.0f分前", age / 60) : String(format: "%.0f秒前", age)
        return "\(base) · \(ago)"
    }

    /// Menu-bar form: no spaces, no CJK — the bar shares its width with every
    /// other status item, and "· 12秒前" costs twice what "·12s" does.
    public static func compactText(rate: Double, age: Double?, stopped: Bool) -> String {
        let base = String(format: "▶%.0f/s", rate)
        guard stopped, let age, age >= 1 else { return base }
        return age >= 60 ? "\(base)·\(Int(age / 60))m" : "\(base)·\(Int(age))s"
    }
}
