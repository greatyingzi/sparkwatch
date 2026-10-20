import Foundation

/// Whole-machine power estimate — the *single* model every surface reads.
///
/// Why a model at all: GB10 cannot measure its wall draw. Re-verified on
/// DGX OS 7.6.0 / driver 580.178.04 (2026-10-20): `/sys/class/powercap` is empty,
/// hwmon exposes temperatures only (acpitz, nvme, mlx5 x4, mt7925 — no
/// `power_input`), there is no `/sys/class/power_supply`, no iio, no typec/ucsi,
/// `perf list` has no energy event, and dmesg mentions no ina/pmbus/hpm. DCGM's
/// CPU/Module power fields read 0.000 and `nvidia-smi -pl` says the power limit
/// is "not supported in current scope". The GPU rail (NVML `power.draw`) is the
/// only real number on the box.
///
/// Why this shape: earlier versions had **two** different models — the UI used
/// `12 + 2.20 × GPU` while the energy ledger used `GPU + cpu(65 W TDP) + 23` — so
/// the same machine printed two different wattages (up to 62 W apart at CPU-heavy
/// load) and only one of them was user-tunable. There is now one formula.
///
/// Coefficients come from a constrained fit (base ≥ 0, monotone) over the
/// measured wall-meter anchors published for the **2026 firmware** on this
/// hardware, not from a single pair of points:
///
/// | anchor | GPU rail | CPU load | wall |
/// |---|---|---|---|
/// | idle, headless (CX7 hot-plug fix in) | 11 W | ~3 % | 22–25 W |
/// | MoE decode, steady | 15 W | ~20 % | ~45 W |
/// | LLM inference, typical | 35.7 W | ~30 % | 60–90 W |
/// | 2-node TP pair (Shelly on the pair) | 47.7 W | ~40 % | 117 W |
/// | CPU saturated (20 cores) | 12 W | 100 % | 120–130 W |
/// | GPU saturated (Vulkan indirect draw) | 87 W | ~20 % | ~170 W (180 incl. 10 W panel) |
///
/// Worst-case residual over those anchors is 10.9 W (RMS 7.8 W). That is the
/// honest ceiling of a software-only estimate: the anchors come from different
/// machines and firmware, and no global formula can do better — see the failure
/// note on `capW`. A one-off calibration against a metered socket replaces
/// these numbers per machine (they are plain data in `settings.json`).
///
/// Reference for the two physical facts baked in:
///  * the 240 W figure is the **adapter rating**, not a measurement — nothing
///    reaches it (a GPU-saturated Spark tops out near 180–200 W), so the cap is
///    200 W rather than the nameplate;
///  * the GB10 SoC has a 140 W budget shared by GPU and CPU (GPU alone caps at
///    120 W), which is why GPU and CPU watts cannot simply be added — the fit
///    above absorbs that coupling instead of pretending it is additive.
public struct PowerEstimate: Codable, Sendable, Equatable {
    public var enabled: Bool = true

    /// Marginal wall watts per watt of GPU-rail draw, absorbing the platform
    /// floor and the CPU work that tracks GPU work in an inference workload.
    public var kGpu: Double = 1.61
    /// Wall watts added by a fully saturated CPU (20 cores), scaled by the
    /// measured CPU load fraction.
    public var kCpu: Double = 95
    /// A Spark that is up but idle draws 22–25 W on current firmware; the fit has
    /// no constant term (a positive intercept cannot be reconciled with the
    /// anchors: solving for one yields a negative base), so the floor is applied
    /// as a clamp instead.
    public var floorW: Double = 20
    /// Measured ceiling on current hardware, deliberately below the 240 W
    /// adapter rating: a wall meter never shows more than ~180–200 W.
    public var capW: Double = 200

    /// Where the coefficients came from. Shown in the UI so a number is never
    /// presented as measured when it is fitted, and so a calibrated machine can
    /// say so.
    public enum Calibration: String, Codable, Sendable {
        case report
        case meter
        case manual
    }
    public var calibration: Calibration = .report

    /// CPU load assumed when the CPU channel has no reading yet. Inference
    /// workloads track the GPU closely, and guessing zero would under-read a
    /// busy CPU by up to ~95 W.
    public static let assumedCPULoad = 0.2

    public init() {}

    /// Tolerant decoding, plus a migration for files written by the two-point
    /// model (`baseW` / `perGpuW` / `maxW`). A hand-edited or older settings file
    /// must never fail wholesale — that silently resets every machine.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        if let k = try c.decodeIfPresent(Double.self, forKey: .kGpu) {
            self.kGpu = k
        } else if let legacy = try c.decodeIfPresent(Double.self, forKey: .perGpuW) {
            // A file carrying exactly the *shipped* two-point values was never
            // tuned by hand — it is just what the old version wrote. Honouring it
            // would freeze the stale fit (and its +13 W idle bias) forever, so it
            // migrates to the new defaults. Anything else is a real user tuning and
            // is preserved as the GPU slope.
            let legacyBase = try c.decodeIfPresent(Double.self, forKey: .baseW) ?? 12
            let legacyCap = try c.decodeIfPresent(Double.self, forKey: .maxW) ?? 240
            let shippedTwoPointFit = legacyBase == 12 && legacy == 2.20 && legacyCap == 240
            if !shippedTwoPointFit { self.kGpu = legacy }
        }
        self.kCpu = try c.decodeIfPresent(Double.self, forKey: .kCpu) ?? 95
        self.floorW = try c.decodeIfPresent(Double.self, forKey: .floorW) ?? 20
        if let cap = try c.decodeIfPresent(Double.self, forKey: .capW) {
            self.capW = cap
        } else if let legacy = try c.decodeIfPresent(Double.self, forKey: .maxW) {
            self.capW = min(legacy, 200)
        }
        self.calibration = try c.decodeIfPresent(Calibration.self, forKey: .calibration) ?? .report
    }

    /// Keys this type has ever written. The legacy ones are decode-only (they
    /// existed in the two-point model) so old files migrate instead of resetting.
    private enum CodingKeys: String, CodingKey {
        case enabled, kGpu, kCpu, floorW, capW, calibration
        case perGpuW, baseW, maxW
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(kGpu, forKey: .kGpu)
        try c.encode(kCpu, forKey: .kCpu)
        try c.encode(floorW, forKey: .floorW)
        try c.encode(capW, forKey: .capW)
        try c.encode(calibration, forKey: .calibration)
    }

    /// How much the caller should trust the number. Never `.good`: this figure is
    /// always modelled, and the UI keeps the `≈` for that reason.
    public enum Confidence: String, Codable, Sendable, Equatable {
        /// All inputs present and inside the calibrated range.
        case fair
        /// Extrapolating, or missing the CPU side — the error can be ±20 W.
        case low
    }

    public struct Reading: Sendable, Equatable, Codable {
        public var wallW: Double
        public var confidence: Confidence
        /// Short Chinese explanation of *why* it is low confidence, or nil.
        public var note: String?
        /// The inputs actually used, so a tooltip can show the arithmetic.
        public var gpuW: Double
        public var cpuLoad: Double
        /// True when the CPU load was assumed rather than measured.
        public var cpuAssumed: Bool

        public init(
            wallW: Double, confidence: Confidence, note: String?,
            gpuW: Double, cpuLoad: Double, cpuAssumed: Bool
        ) {
            self.wallW = wallW
            self.confidence = confidence
            self.note = note
            self.gpuW = gpuW
            self.cpuLoad = cpuLoad
            self.cpuAssumed = cpuAssumed
        }
    }

    /// The one entry point. `cpuFreqRatio` (current ÷ maximum clock, 0.6…1) lets
    /// the CPU term follow frequency instead of pretending every busy cycle costs
    /// the same: dynamic power tracks clock, and a 20-core Grace part runs its two
    /// clusters at 3.9 GHz and 2.808 GHz respectively.
    public func estimate(
        gpuW: Double?,
        cpuUsagePct: Double?,
        cpuFreqRatio: Double? = nil
    ) -> Reading? {
        guard enabled, let gpuW, gpuW >= 0 else { return nil }
        var notes: [String] = []
        var confidence = Confidence.fair

        var load: Double
        var assumed = false
        if let pct = cpuUsagePct {
            load = min(1, max(0, pct / 100))
            if let ratio = cpuFreqRatio, ratio > 0.2 {
                // Busy time at a lower clock costs proportionally less; the factor
                // is clamped because the two clusters report separate policies.
                load *= min(1, max(0.6, ratio))
            }
        } else {
            load = Self.assumedCPULoad
            assumed = true
            confidence = .low
            notes.append("CPU 占用未读到，按 20% 估")
        }

        var wall = kGpu * gpuW + kCpu * load
        wall = min(max(wall, floorW), capW)

        if gpuW > 90 {
            confidence = .low
            notes.append("GPU 轨 \(Int(gpuW.rounded()))W 超出实测锚点区间")
        } else if load > 0.55 && gpuW < 30 {
            confidence = .low
            notes.append("CPU 密集区间锚点少，误差可达 ±10W")
        }
        return Reading(
            wallW: wall,
            confidence: confidence,
            note: notes.isEmpty ? nil : notes.joined(separator: "；"),
            gpuW: gpuW,
            cpuLoad: load,
            cpuAssumed: assumed
        )
    }

    /// Convenience for call sites that only have the GPU rail (menu-bar text,
    /// task summary). Prefer `estimate(gpuW:cpuUsagePct:cpuFreqRatio:)`.
    public func wholeMachineW(gpuW: Double?) -> Double? {
        estimate(gpuW: gpuW, cpuUsagePct: nil)?.wallW
    }

    /// The arithmetic, for tooltips: "≈1.61 × 35.1W + 95 × 10%".
    public func formula(for reading: Reading) -> String {
        String(
            format: "≈ %.2f × %.1fW + %.0f × %.0f%% = %.0fW",
            kGpu, reading.gpuW, kCpu, reading.cpuLoad * 100, reading.wallW
        )
    }
}
