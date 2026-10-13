import Foundation

/// How often to ask the engine for its counters.
///
/// A fixed cadence cannot satisfy both ends of this: the rate is a counter
/// delta, so the *first* reading after a request starts can only appear on the
/// probe following the start — at a 5 s cadence that is up to 5 s of "nothing to
/// show" while the box is plainly working. But polling a loopback-only engine
/// costs an SSH round trip per probe, and paying that every second while the
/// deployment sits idle is waste.
///
/// So the cadence follows the cheapest signal that something is happening: the
/// GPU utilisation and power from the 1 Hz dashboard stream. Working → poll like
/// it matters (2 s, so the first rate lands in ~2 s). Quiet → back off (6 s).
/// The engine's own report of in-flight work counts as a hint too, so a slow
/// request that barely touches the GPU still keeps the fast cadence.
public enum InferenceCadence {
    /// While work is visible: short enough that the first rate appears almost
    /// immediately, long enough not to hammer the SSH channel.
    public static let active: Double = 2
    /// While nothing is happening. Idle counters do not need a 2 s resolution —
    /// there is nothing to see, and the value does not change.
    public static let quiet: Double = 6

    /// GPU utilisation above this counts as "the box is working".
    public static let busyUtilisationPct: Double = 15
    /// …and so does drawing more than idle watts.
    public static let busyPowerW: Double = 25

    /// - Parameters:
    ///   - gpuUtil: last utilisation from the dashboard channel (1 Hz, cheap).
    ///   - powerW: last power draw, same source.
    ///   - engineBusy: the engine's own in-flight/decoding report, when it has one.
    public static func interval(
        gpuUtil: Double?,
        powerW: Double?,
        engineBusy: Bool
    ) -> Double {
        if engineBusy { return active }
        if let util = gpuUtil, util >= busyUtilisationPct { return active }
        if let power = powerW, power >= busyPowerW { return active }
        return quiet
    }
}
