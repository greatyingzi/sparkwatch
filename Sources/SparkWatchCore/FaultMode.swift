import Foundation

/// Short-window temperature trend, because the absolute line alone is useless here.
///
/// The published failure curve for this hardware: under sustained load the SM
/// clock falls 2450 → 1475 within ~2.5 minutes, the ACPI zone peaks at 96 °C, and
/// the box **hard power-offs** — the last sample before cutoff read 92.2 °C on the
/// zone while `nvidia-smi` said 84 °C. Two consequences:
///
///  * the zone's own trip point is 104.8 °C, so a threshold relative to it (e.g.
///    "critical within 6 °C", i.e. 98.8 °C) can never fire before the machine is
///    already off;
///  * healthy boxes under sustained inference sit at 78–91 °C, so a warn line low
///    enough to be useful for a *bad* box would be lit permanently on a good one.
///
/// The discriminator is therefore the **rate of climb**, not the level: 92 → 96 °C
/// in 150 s is ~1.6 °C/min, while a healthy box oscillates around a plateau. This
/// type supplies that slope; the rule itself lives in `HealthEvaluator`.
public struct ThermalTrend: Sendable {
    public struct Reading: Sendable, Equatable {
        /// °C per minute over the window (positive = heating up).
        public var slopePerMinute: Double
        /// How much time the window actually covers.
        public var spanSeconds: Double
        public var deltaC: Double

        public init(slopePerMinute: Double, spanSeconds: Double, deltaC: Double) {
            self.slopePerMinute = slopePerMinute
            self.spanSeconds = spanSeconds
            self.deltaC = deltaC
        }
    }

    private var samples: [(at: Date, c: Double)] = []
    /// The most recent reading, whether or not *this* call had enough data yet.
    public private(set) var latest: Reading?
    /// Long enough to see a 2.5-minute collapse, short enough to react.
    public static let window: TimeInterval = 300
    /// A slope over less than this is noise from one load burst.
    public static let minSpan: TimeInterval = 90
    public static let minSamples = 4
    /// `evaluate()` runs on every UI tick; without this the window fills with a
    /// hundred copies of the same sample and weights the newest second.
    public static let minSampleGap: TimeInterval = 3

    public init() {}

    public mutating func reset() {
        samples.removeAll()
        latest = nil
    }

    public mutating func update(at: Date, tempC: Double) -> Reading? {
        if let last = samples.last,
            at.timeIntervalSince(last.at) < Self.minSampleGap,
            abs(tempC - last.c) < 0.3
        {
            return latest
        }
        samples.append((at, tempC))
        let cutoff = at.addingTimeInterval(-Self.window)
        if let firstInside = samples.firstIndex(where: { $0.at >= cutoff }) {
            samples.removeFirst(firstInside)
        } else {
            samples.removeAll()
        }
        if let reading = Self.slope(samples) { latest = reading }
        return latest
    }

    /// Least squares over the window. Using the endpoints only would make one
    /// spiky sample look like a trend.
    public static func slope(_ points: [(at: Date, c: Double)]) -> Reading? {
        guard points.count >= minSamples, let first = points.first, let last = points.last
        else { return nil }
        let span = last.at.timeIntervalSince(first.at)
        guard span >= minSpan else { return nil }
        let t0 = first.at.timeIntervalSince1970
        let xs = points.map { $0.at.timeIntervalSince1970 - t0 }
        let ys = points.map(\.c)
        let n = Double(points.count)
        let meanX = xs.reduce(0, +) / n
        let meanY = ys.reduce(0, +) / n
        var num = 0.0
        var den = 0.0
        for (x, y) in zip(xs, ys) {
            num += (x - meanX) * (y - meanY)
            den += (x - meanX) * (x - meanX)
        }
        guard den > 0 else { return nil }
        let perSecond = num / den
        return Reading(
            slopePerMinute: perSecond * 60,
            spanSeconds: span,
            deltaC: last.c - first.c
        )
    }
}

/// Is a fixed clock in effect? (`nvidia-smi -lgc`.)
///
/// Matters as an energy lever and as a state that silently disappears: a clock
/// lock does not survive a reboot and needs a systemd oneshot to come back, so
/// "I locked it last week" is a belief the monitor can check.
///
/// Detection cannot read the lock back: the vendor tool keeps reporting the same
/// `Applications`/`Max Clocks` (2418/3003) whether or not a lock is applied — the
/// published method is to watch `clocks.current.sm` under load instead. A locked
/// box therefore shows a *flat* clock in a narrow band (measured 2164–2184 MHz for
/// a 2200 MHz lock, i.e. binning noise around the cap), while an unlocked box
/// boosts higher and wanders. Anything in between is reported as unknown rather
/// than guessed, and a thermally throttled box is never called "locked".
public enum ClockLockState: Sendable, Equatable, Codable {
    case locked(mhz: Double)
    case unlocked
    case unknown

    public var label: String {
        switch self {
        case .locked(let mhz): String(format: "疑似锁频 %.0f MHz", mhz)
        case .unlocked: "未锁频（自由 boost）"
        case .unknown: "锁频未知（负载不足）"
        }
    }

    public var isLocked: Bool {
        if case .locked = self { return true }
        return false
    }
}

public struct ClockLockDetector: Sendable {
    private var window: [(at: Date, mhz: Double)] = []
    /// Needs enough flat samples to tell "capped" from "momentarily stable".
    public static let minSpan: TimeInterval = 45
    public static let minSamples = 5
    public static let windowSeconds: TimeInterval = 150
    /// Everything at or below this is a plausible lock setting (no Spark SKU
    /// boosts past ~2.4 GHz without a lock, and locks are 1400–2200 in practice).
    public static let lockCeilingMHz: Double = 2300
    /// Above this the clock is clearly free.
    public static let freeFloorMHz: Double = 2350
    /// A locked clock is flat within binning noise.
    public static let maxSpreadMHz: Double = 40

    public init() {}

    public mutating func update(
        at: Date,
        clockMHz: Double?,
        utilPct: Double?,
        thermalSlowdown: Bool
    ) -> ClockLockState {
        let cutoff = at.addingTimeInterval(-Self.windowSeconds)
        if let firstInside = window.firstIndex(where: { $0.at >= cutoff }) {
            window.removeFirst(firstInside)
        } else {
            window.removeAll()
        }
        // Only load-time samples say anything: an idle box sits at ~2400 MHz
        // regardless of any lock.
        if let clock = clockMHz, let util = utilPct, util >= 75, !thermalSlowdown, clock > 0 {
            window.append((at, clock))
        }
        guard window.count >= Self.minSamples,
            let first = window.first, let last = window.last,
            last.at.timeIntervalSince(first.at) >= Self.minSpan
        else { return .unknown }

        let values = window.map(\.mhz)
        let mean = values.reduce(0, +) / Double(values.count)
        let spread = (values.max() ?? 0) - (values.min() ?? 0)
        if mean >= Self.freeFloorMHz { return .unlocked }
        if mean <= Self.lockCeilingMHz && spread <= Self.maxSpreadMHz {
            return .locked(mhz: mean)
        }
        return .unknown
    }
}

/// The four failure signatures this hardware is documented to produce, as data.
///
/// The menu bar and the cards need a one-token answer, and each mode has a
/// different *action* — which is the whole point of distinguishing them:
///
///  * `clockCollapse`  — busy at ≤25 W with collapsed clocks: the classic
///    low-power wedge; action = full power drain. (Detected in `HealthEvaluator`,
///    which owns the required consecutive-sample streak.)
///  * `pciePowerDefect` — power pinned near 27–30 W at 0 % utilisation with
///    `insufficient power on the PCIe slot` events *after* boot: hardware, action
///    = RMA. The after-boot gate is load-bearing: every Spark in this fleet logs
///    that line four times during boot (one per ConnectX-7 function) and runs
///    perfectly, so a naive "dmesg contains it" rule would mark healthy boxes for
///    return.
///  * `thermalLimit`   — power riding the limit at high zone temperature with the
///    thermal-slowdown bit set: not a defect, action = clock lock / airflow /
///    stand it upright.
///  * `driverLowPower` — ~5 W at 0 % with a clean kernel log: the 550.x driver
///    bug, fixed in 580.x. Only offered when the running driver is actually older
///    than that, otherwise the advice is nonsense.
public enum FaultMode: String, Sendable, Equatable, Codable {
    case clockCollapse
    case pciePowerDefect
    case thermalLimit
    case driverLowPower

    public var label: String {
        switch self {
        case .clockCollapse: "低功耗卡死"
        case .pciePowerDefect: "供电不足"
        case .thermalLimit: "热节流"
        case .driverLowPower: "驱动低功耗 bug"
        }
    }

    /// One-token form for the menu bar / chips.
    public var token: String {
        switch self {
        case .clockCollapse: "卡死"
        case .pciePowerDefect: "供电"
        case .thermalLimit: "热节流"
        case .driverLowPower: "驱动"
        }
    }

    public var action: String {
        switch self {
        case .clockCollapse: "断电放电后重启（拔电、等 5 分钟再上电）"
        case .pciePowerDefect: "PD 供电缺陷，双闪固件无效 → 联系 RMA"
        case .thermalLimit: "不是缺陷：锁频（-lgc 2200）/ 改善风道 / 立式摆放"
        case .driverLowPower: "升级到 580.x 驱动 + CUDA 13"
        }
    }
}

/// The three stateless signatures above. The wedge needs a streak and stays in
/// `HealthEvaluator`.
public enum FaultModeClassifier {
    public struct Verdict: Sendable, Equatable {
        public var mode: FaultMode
        public var critical: Bool
        public var message: String
    }

    /// `pcieLatePowerEvents` must already exclude the boot-time burst
    /// (`SshProbe` filters events in the first 180 s of uptime).
    public static func classifyHardware(
        utilPct: Double?,
        powerW: Double?,
        gpuTempC: Double?,
        acpitzC: Double?,
        thermalLimitC: Double?,
        thermalSlowdown: Bool,
        pcieLatePowerEvents: Int?,
        driverVersion: String?
    ) -> Verdict? {
        // 1. Power-delivery defect: pinned low power at zero work, with proof that
        // the box itself complained *after* boot.
        if let power = powerW, let util = utilPct,
            let late = pcieLatePowerEvents, late > 0,
            util <= 5, power >= 20, power <= 45
        {
            return Verdict(
                mode: .pciePowerDefect,
                critical: true,
                message: String(
                    format: "GPU 轨卡在 %.0fW 而利用率 %.0f%%，启动后仍有 %d 次 PCIe 供电不足事件 → 供电缺陷",
                    power, util, late
                )
            )
        }

        // 3. Thermal limiting: not a fault, but it *is* the reason for lost
        // performance, and it has a cheap remedy.
        if thermalSlowdown, let util = utilPct, util >= 40, let power = powerW, power >= 55 {
            let zone = acpitzC.map { String(format: "，热区 %.0f°C", $0) } ?? ""
            let limit = thermalLimitC.map { String(format: "/%.0f°C", $0) } ?? ""
            return Verdict(
                mode: .thermalLimit,
                critical: false,
                message: String(format: "GPU %.0f%% 但触发硬件热降频（%.0fW%@%@）→ 锁频/风道可救", util, power, zone, limit)
            )
        }

        // 4. The 5 W driver bug — only meaningful on a driver older than 580.
        if let power = powerW, let util = utilPct,
            util <= 5, power > 0, power <= 8,
            let major = driverMajor(driverVersion), major < 580
        {
            return Verdict(
                mode: .driverLowPower,
                critical: true,
                message: String(
                    format: "GPU 轨仅 %.1fW、利用率 %.0f%%，驱动 %@ 属 550.x 已知低功耗 bug",
                    power, util, driverVersion ?? "?"
                )
            )
        }
        return nil
    }

    /// "580.178.04" → 580. Nil when the version string is missing or unparseable.
    public static func driverMajor(_ version: String?) -> Int? {
        guard let version, let head = version.split(separator: ".").first else { return nil }
        return Int(head)
    }
}
