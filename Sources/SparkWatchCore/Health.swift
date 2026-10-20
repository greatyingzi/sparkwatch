import Foundation

// GB10 health rules. Thresholds are taken from joeynyc/spark-doctor (MIT,
// © 2026) — field-reported DGX Spark behaviour rather than desk guesses:
//
//   memory.py : MemAvailable < 8 GB, < 16 GB warn, PSI > 0.25 critical,
//               PSI > 0.10 warn, swap used > 8 GB warn.
//               We keep spark-doctor's numbers but not its severity for the
//               absolute figure: on unified memory a resident model parks
//               MemAvailable at 7-8 GB on a 121 GiB box while PSI stays 0.00, so
//               "low available" alone is 注意 and PSI (real stall time) is what
//               escalates — see the memory block below.
//   power.py  : util >= 80 % while power <= 25 W = possible low-power state;
//               sustained (>= 3 samples) = critical, clock <= 800 MHz raises
//               confidence. We make the clock *required* rather than a hint: on a
//               TB-parallel pair the utilisation reading alone fires on healthy
//               collective waits (see the power block below).
//   thermal.py: max temp >= 85 °C warn, >= 90 °C critical — kept for the *GPU*
//               rail, where GB10 exposes no usable limit (`temperature.gpu.tlimit`
//               returns 4, shutdown/slowdown are N/A), so there is nothing to be
//               relative to and the field-reported numbers stand.
//               The ACPI zone is treated relative to the platform's own declared
//               trip point (104 °C here) — see the thermal block below.
//
// The "busy but sipping power" check is the one that earns its keep: the box
// runs at a quarter speed while every number still looks green, and the usual
// cure is a full power-drain (unplug, wait, boot).

public enum HealthLevel: Int, Comparable, Sendable {
    case ok = 0
    case unknown = 1
    case warning = 2
    case critical = 3

    public static func < (lhs: HealthLevel, rhs: HealthLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .ok: "正常"
        case .unknown: "未知"
        case .warning: "注意"
        case .critical: "异常"
        }
    }
}

/// Which rule fired, as data rather than prose. The menu bar needs a one-token
/// answer ("91°", "96% 20W", "内存 7G") and must not parse its own reason
/// strings to get it — the reasons are written for a human reading the popover.
public enum HealthCause: String, Sendable, Equatable {
    case unreachable
    case engineFatal
    case engineStalled
    case gpuThermal
    case cpuThermal
    /// The hottest ACPI zone is *climbing* toward its trip point, before it is
    /// close enough for the absolute rule to fire. This is the only warning that
    /// can arrive before the documented hard power-off (the box dies at ~96 °C
    /// while its declared trip point is 104.8 °C).
    case thermalTrend
    case memoryPressure
    case memoryLow
    case swap
    case lowPowerWedge
    /// A documented hardware/software failure signature (see `FaultMode`).
    case faultMode
    /// The official telemetry channel is off because no one has signed in.
    case needsLogin
    /// A failure with no structured rule behind it (e.g. a probe error).
    case other
}

public struct HealthReport: Sendable, Equatable {
    public var level: HealthLevel
    public var reasons: [String]
    /// Structured form of `reasons`, in the order the rules ran.
    public var causes: [HealthCause]
    /// Deserves the menu-bar ⚠: the box is unreachable, or one of the failures
    /// that a green dashboard hides (thermal, memory-pressure stalls, the
    /// low-power wedge). Ordinary "loaded, so memory is tight" warnings show as
    /// a coloured dot and in the popover — a node that is doing its job must not
    /// sit in permanent alarm.
    public var alert: Bool
    /// Which documented failure signature matched, for the UI chip and for the
    /// operator's next action. Nil when nothing matched.
    public var faultMode: FaultMode?

    public init(
        level: HealthLevel,
        reasons: [String],
        causes: [HealthCause] = [],
        alert: Bool = false,
        faultMode: FaultMode? = nil
    ) {
        self.level = level
        self.reasons = reasons
        self.causes = causes
        self.alert = alert
        self.faultMode = faultMode
    }

    public static let unknown = HealthReport(level: .unknown, reasons: [])
    public static let ok = HealthReport(level: .ok, reasons: [])
}

/// Stateful because the low-draw rule needs consecutive samples, not one, and the
/// thermal rule needs a short history to compute a slope.
public struct HealthEvaluator: Sendable {
    private var lowDrawStreak = 0
    private var thermalTrend = ThermalTrend()

    public init() {}

    /// The slope the evaluator last computed, for the UI's "热区在爬升" row.
    public var lastThermalTrend: ThermalTrend.Reading? { thermalTrend.latest }

    public mutating func evaluate(
        gpu: GpuSample,
        system: SystemSample,
        source: DataSource,
        error: String?,
        inference: InferenceSample? = nil,
        awaitingCredentials: Bool = false,
        at now: Date = Date()
    ) -> HealthReport {
        guard source != .down else {
            return HealthReport(
                level: .critical,
                reasons: [error ?? "无响应"],
                causes: [.unreachable],
                alert: true
            )
        }

        var level: HealthLevel = .ok
        var reasons: [String] = []
        var causes: [HealthCause] = []
        var alert = false
        var faultMode: FaultMode?

        func flag(_ candidate: HealthLevel, _ reason: String, cause: HealthCause, alerting: Bool = false) {
            if candidate > level { level = candidate }
            if alerting { alert = true }
            reasons.append(reason)
            if !causes.contains(cause) { causes.append(cause) }
        }

        // Absolute for the GPU rail: GB10 reports no usable limit for it
        // (`tlimit` = 4, shutdown/slowdown N/A), so these are spark-doctor's
        // field-reported values rather than something relative to a declaration.
        if let temp = gpu.tempC {
            if temp >= 90 {
                flag(.critical, String(format: "GPU 温度 %.0f°C ≥ 90", temp), cause: .gpuThermal, alerting: true)
            } else if temp >= 85 {
                flag(.warning, String(format: "GPU 温度 %.0f°C ≥ 85", temp), cause: .gpuThermal)
            }
        }
        // The CPU-side reading is an ACPI thermal zone, and GB10 declares its
        // limit (trip point 104 °C). Thresholds are therefore relative to that
        // declaration: a fixed 90 °C line fired a standing ⚠ at a reading the
        // hardware considers 14 °C below its ceiling — the classic false alarm
        // that teaches people to ignore the icon. The margins come from what the
        // box actually does: these zones live at 78-91 °C under sustained
        // inference, so a line 20 °C below the ceiling would be lit permanently.
        // Warn within 12 °C of the ceiling, alert within 6 °C.
        if let cpuTemp = system.cpuTempC {
            let limit = system.thermalLimitC ?? 100
            let margin = limit - cpuTemp
            // Slope over the last few minutes. This is what can arrive *before*
            // the trip point: the published crash curve climbs 92 → 96 °C in
            // ~150 s and the box then cuts power, i.e. 1.5 °C/min. Waiting for
            // the absolute line at 12 °C of margin means hearing about it one
            // sample before it dies.
            let trend = thermalTrend.update(at: now, tempC: cpuTemp)
            let climbing = (trend?.slopePerMinute ?? 0) >= 0.5 && (trend?.deltaC ?? 0) >= 2

            if margin <= 6 {
                flag(.critical,
                     String(format: "热区温度 %.0f°C（平台上限 %.0f°C）", cpuTemp, limit),
                     cause: .cpuThermal,
                     alerting: true)
            } else if margin <= 12 {
                // Climbing while this close to the ceiling is the documented
                // power-off recipe, not a warning to check later.
                flag(climbing ? .critical : .warning,
                     String(format: "热区温度 %.0f°C（平台上限 %.0f°C）", cpuTemp, limit)
                        + (climbing ? String(format: "，仍在爬升 %+.1f°C/min", trend?.slopePerMinute ?? 0) : ""),
                     cause: climbing ? .thermalTrend : .cpuThermal,
                     alerting: climbing)
            } else if margin <= 22, climbing {
                flag(.warning,
                     String(format: "热区在爬升 %+.1f°C/min（%.0f°C，距上限 %.0f°C）",
                            trend?.slopePerMinute ?? 0, cpuTemp, margin),
                     cause: .thermalTrend)
            }
        }

        if let pressure = system.memPressureAvg10 {
            if pressure > 0.25 {
                flag(.critical, String(format: "内存压力 PSI full avg10 %.2f > 0.25", pressure),
                     cause: .memoryPressure, alerting: true)
            } else if pressure > 0.10 {
                flag(.warning, String(format: "内存压力 PSI full avg10 %.2f > 0.10", pressure),
                     cause: .memoryPressure)
            }
        }

        if let available = system.memAvailableBytes {
            let availableGB = Double(available) / 1_000_000_000
            let pressure = system.memPressureAvg10 ?? 0
            // Unified memory makes the absolute figure a poor severity signal on
            // its own: a resident model legitimately parks MemAvailable near the
            // floor (7-8 GB on a 121 GiB box serving a 284B model), and that is
            // the box doing its job, not a fault. PSI is the honest escalator —
            // it measures time actually spent stalled on memory. Below 2 GB OOM
            // is imminent either way, so that stays critical on its own.
            if availableGB < 2 {
                flag(.critical, String(format: "可用内存 %.1f GB < 2（随时可能 OOM）", availableGB),
                     cause: .memoryLow, alerting: true)
            } else if availableGB < 8 {
                if pressure > 0.25 {
                    flag(.critical, String(format: "可用内存 %.1f GB < 8 且内存压力 PSI %.2f > 0.25", availableGB, pressure),
                         cause: .memoryLow, alerting: true)
                } else {
                    flag(.warning, String(format: "可用内存 %.1f GB < 8（PSI %.2f，无人等内存）", availableGB, pressure),
                         cause: .memoryLow)
                }
            } else if availableGB < 16 {
                flag(.warning, String(format: "可用内存 %.1f GB < 16", availableGB), cause: .memoryLow)
            }
            // 占比 < 15 % used to be a separate rule; it fires at the same time as
            // the absolute one on every plausible machine size, so it only ever
            // duplicated the reason line.
        }

        if let swapUsed = system.swapUsedBytes, swapUsed > 8_000_000_000 {
            flag(.warning, String(format: "swap 已用 %.1f GB > 8", Double(swapUsed) / 1e9), cause: .swap)
        }

        // Busy but drawing almost nothing: the documented low-power wedge.
        //
        // "Busy" alone is not evidence on a distributed deployment. `utilization.gpu`
        // reports that a kernel was resident, not that work is happening: a
        // tensor-parallel rank waiting on its peer link sits at 90 %+ while
        // drawing ~20 W, and GB10 idles at 2400 MHz, so a healthy pair produced
        // a standing ⚠ (observed live: 96 % / 23 W while decoding at 27-65 tok/s).
        // The wedge has a different signature — *collapsed clocks* — which
        // spark-doctor's rule already names as the confidence signal. Require it.
        if let util = gpu.utilPct, let power = gpu.powerW {
            let clock = gpu.smClockMHz
            let looksBusy = util >= 80 && power <= 25
            // Unknown clock: never escalate on a guess (a false ⚠ is worse than a
            // missed wedge for a monitor — the user cannot act on either).
            let wedgeEvidence = looksBusy && (clock.map { $0 <= 800 } ?? false)
            if wedgeEvidence {
                lowDrawStreak += 1
            } else {
                lowDrawStreak = 0
            }
            if lowDrawStreak >= 3 {
                flag(
                    .critical,
                    String(format: "GPU 忙 %.0f%% 但功耗仅 %.1f W 且时钟仅 %.0f MHz（连续 %d 次）→ 低功耗卡死",
                           util, power, clock ?? 0, lowDrawStreak),
                    cause: .lowPowerWedge,
                    alerting: true
                )
                faultMode = .clockCollapse
            } else if lowDrawStreak > 0 {
                flag(.warning, String(format: "GPU 忙 %.0f%% 但功耗仅 %.1f W，时钟 %.0f MHz", util, power, clock ?? 0),
                     cause: .lowPowerWedge)
            }
        }

        // The remaining documented failure signatures: power-delivery defect,
        // thermal limiting, the 5 W driver bug. Each has a different action, which
        // is the only reason to tell them apart — see `FaultMode`.
        if let verdict = FaultModeClassifier.classifyHardware(
            utilPct: gpu.utilPct,
            powerW: gpu.powerW,
            gpuTempC: gpu.tempC,
            acpitzC: system.cpuTempC,
            thermalLimitC: system.thermalLimitC,
            thermalSlowdown: gpu.throttle?.thermal ?? false,
            pcieLatePowerEvents: system.pcieLatePowerEvents,
            driverVersion: system.driverVersion
        ), faultMode == nil {
            faultMode = verdict.mode
            flag(
                verdict.critical ? .critical : .warning,
                verdict.message + " → " + verdict.mode.action,
                cause: .faultMode,
                alerting: verdict.critical
            )
        }

        // The official telemetry channel is off because nobody has signed in.
        //
        // This is not a hardware condition and it does not come and go with load:
        // every other rule here describes something the box is doing, while this
        // one stays until a human types a password. It therefore earns a place in
        // the menu bar even at warning level (see `StatusBarText.isDeviating`).
        // The alternative is what happened on 2026-10-16: the SSH fallback kept
        // every number plausible, so the channel that had died was never mentioned
        // anywhere the user would look.
        if awaitingCredentials {
            flag(.warning, CredentialGate.needsLoginReason, cause: .needsLogin)
        }

        if let error, level == .ok, error != CredentialGate.needsLoginReason {
            flag(.warning, error, cause: .other)
        }

        // The engine's own verdict, reported by the engine itself.
        //
        // TensorFold raises `engine_fatal` once it is past saving (both ranks need
        // a restart) while every counter it exposes keeps looking plausible — the
        // archetype of the failure a green dashboard hides. `requests_stalled`
        // means work is running past the engine's own stall threshold, which is a
        // warning: it is slow, not dead.
        if let inference {
            if inference.engineFatal {
                flag(
                    .critical,
                    "推理引擎进入 fatal 状态（\(inference.model ?? "未知模型")）→ 需要重启两个 rank",
                    cause: .engineFatal,
                    alerting: true
                )
            } else if let stalled = inference.stalledRequests, stalled > 0 {
                flag(
                    .warning,
                    String(format: "%.0f 个请求超过引擎的停滞阈值", stalled),
                    cause: .engineStalled
                )
            }
        }
        return HealthReport(
            level: level, reasons: reasons, causes: causes, alert: alert, faultMode: faultMode
        )
    }
}

