import Foundation
import Testing

@testable import SparkWatchCore

/// The menu bar is read dozens of times a day, so what it says (and what it
/// stays quiet about) is behaviour, not decoration — these are regression tests
/// for it rather than for a string.
///
/// Shape since the 2026-10 fleet-dot change:
/// `[⚠] <fleet dot> [deviating machine…] [▶speed] [alive/n] [≈power]`
/// — **one** dot for the whole fleet, and per-machine slots only for machines
/// that have something to say (or, in 详细, for every machine).
@Suite("Status bar text")
struct StatusBarTextTests {
    // MARK: - Builders

    private func node(
        name: String,
        source: DataSource = .dashboard,
        health: HealthReport = .ok,
        util: Double? = 12,
        temp: Double? = 64,
        // No GPU rail unless a test asks for one: the compact preset draws the
        // fitted wall draw by default, and a silent default rail would put an
        // ≈W figure into every unrelated expectation.
        power: Double? = nil,
        clock: Double = 2400,
        availableGB: Double? = 60,
        tps: Double? = nil,
        prefilling: Double? = nil,
        running: Double? = nil,
        oldestSeconds: Double? = nil
    ) -> NodeSnapshot {
        var gpu = GpuSample(
            utilPct: util,
            tempC: temp,
            powerW: power,
            memTotalBytes: 121 * 1_073_741_824,
            memUsedBytes: 100 * 1_073_741_824
        )
        gpu.smClockMHz = clock
        var system = SystemSample()
        system.cpuUsagePct = 5
        system.cpuTempC = 61
        system.thermalLimitC = 104
        if let availableGB { system.memAvailableBytes = UInt64(availableGB * 1_000_000_000) }
        var inference: InferenceSample?
        if tps != nil || prefilling != nil || running != nil || oldestSeconds != nil {
            inference = InferenceSample()
            inference?.decodeTPS = tps
            inference?.prefilling = prefilling
            inference?.running = running
            inference?.oldestSeconds = oldestSeconds
        }
        return NodeSnapshot(
            id: UUID(),
            name: name,
            host: "\(name).local",
            source: source,
            gpu: gpu,
            system: system,
            inference: inference,
            health: health
        )
    }

    private func text(
        _ nodes: [NodeSnapshot],
        _ mutate: (inout StatusBarSettings) -> Void = { _ in },
        power: PowerEstimate = PowerEstimate()
    ) -> String {
        var settings = StatusBarSettings()
        mutate(&settings)
        return StatusBarText.text(for: nodes, settings: settings, powerEstimate: power)
    }

    private func segments(
        _ nodes: [NodeSnapshot],
        _ mutate: (inout StatusBarSettings) -> Void = { _ in }
    ) -> [StatusSegment] {
        var settings = StatusBarSettings()
        mutate(&settings)
        return StatusBarText.segments(for: nodes, settings: settings)
    }

    private func alert(_ cause: HealthCause, _ reason: String, temp: Double = 91) -> HealthReport {
        HealthReport(level: .critical, reasons: [reason], causes: [cause], alert: true)
    }

    // MARK: - The complaint this mode exists for

    /// "00 01" — two constants, zero signal. A healthy idle pair must not spend
    /// the widest element in the bar to say nothing.
    @Test func healthyNodesDoNotPrintTheirNames() {
        let fleet = [node(name: "spark-00"), node(name: "spark-01")]
        let bar = text(fleet)
        #expect(bar == "●")
        #expect(!bar.contains("00") && !bar.contains("01"))
    }

    @Test func healthyNodesStayQuietWhileGenerating() {
        let fleet = [node(name: "spark-00", tps: 18), node(name: "spark-01", tps: 14)]
        #expect(text(fleet) == "● ▶32/s")
    }

    /// A prefill produces no decode tokens, so a bar that only ever showed a rate
    /// stayed silent through the phase a long-context box spends most of its time
    /// in — "working hard" and "idle" looked identical. It has to say something.
    @Test func prefillingSaysSoEvenWithoutARate() {
        let fleet = [node(name: "spark-00", prefilling: 1)]
        #expect(text(fleet) == "● ⇡×1")
    }

    @Test func inFlightWithoutARateFallsBackToTheCount() {
        let fleet = [node(name: "spark-00", running: 2)]
        #expect(text(fleet) == "● ×2")
    }

    // MARK: - One dot for the whole fleet

    /// The rule that replaced "a dot per machine": the bar's width must not grow
    /// with the fleet while nothing is wrong. `● ●` for a pair was two identical
    /// constants — it named neither machine and said nothing.
    @Test func fleetDotIsOneGlyphAtAnyFleetSize() {
        let two = (0..<2).map { node(name: String(format: "spark-%02d", $0)) }
        let twelve = (0..<12).map { node(name: String(format: "spark-%02d", $0)) }
        #expect(text(two) == "●")
        #expect(text(twelve) == "●")
        #expect(text(two).count == text(twelve).count)
    }

    /// Worst, not first: a fleet is as healthy as its sickest machine, and a
    /// warning must not be hidden by a healthy neighbour.
    @Test func fleetDotCarriesTheWorstTone() {
        let healthy = [node(name: "spark-00"), node(name: "spark-01")]
        #expect(segments(healthy).first { $0.text == "●" }?.tone == .good)

        let warned = [
            node(name: "spark-00"),
            node(
                name: "spark-01",
                health: HealthReport(
                    level: .warning,
                    reasons: ["可用内存 7.2 GB < 8（PSI 0.00，无人等内存）"],
                    causes: [.memoryLow]
                ),
                availableGB: 7.2
            ),
        ]
        #expect(segments(warned).first { $0.text == "●" }?.tone == .warning)

        let degraded = [node(name: "spark-00", source: .sshFallback)]
        #expect(segments(degraded).first { $0.text == "●" }?.tone == .degraded)
    }

    /// 极简's promise is one character. It swaps its glyph on trouble instead of
    /// appending a ⚠ or a `+N`, so a twelve-machine fleet with problems still
    /// occupies one column.
    @Test func minimalSwapsItsGlyphInsteadOfAddingTokens() {
        let healthy = (0..<12).map { node(name: String(format: "spark-%02d", $0)) }
        #expect(text(healthy) { $0.mode = .minimal } == "●")

        let oneHot = [
            node(name: "spark-00"),
            node(name: "spark-01", health: alert(.gpuThermal, "GPU 温度 91°C ≥ 90"), temp: 91),
        ]
        #expect(text(oneHot) { $0.mode = .minimal } == "⚠")

        let allDown = (0..<6).map {
            node(
                name: String(format: "spark-%02d", $0),
                source: .down,
                health: alert(.unreachable, "无响应")
            )
        }
        #expect(text(allDown) { $0.mode = .minimal } == "✕")

        // …and exactly one segment in every one of those cases.
        #expect(segments(oneHot) { $0.mode = .minimal }.count == 1)
    }

    // MARK: - A name has to earn its place

    @Test func downNodeIsNamedAndCounted() {
        let fleet = [
            node(name: "spark-00"),
            node(name: "spark-01", source: .down, health: HealthReport(
                level: .critical, reasons: ["无响应"], causes: [.unreachable], alert: true
            )),
        ]
        #expect(text(fleet) == "⚠ ● 01 ✕ 1/2")
    }

    @Test func hotNodeIsNamedWithItsTemperature() {
        let fleet = [
            node(name: "spark-00"),
            node(name: "spark-01", health: HealthReport(
                level: .critical, reasons: ["GPU 温度 91°C ≥ 90"], causes: [.gpuThermal], alert: true
            ), temp: 91),
        ]
        #expect(text(fleet) == "⚠ ● 01 91°")
    }

    /// The wedge is the failure a green dashboard hides; its indicator is the
    /// signature itself (busy percentage next to the watts it is not drawing).
    @Test func lowPowerWedgeShowsBothHalvesOfItsSignature() {
        let fleet = [node(
            name: "spark-00",
            health: HealthReport(
                level: .critical,
                reasons: ["GPU 忙 96% 但功耗仅 20 W 且时钟仅 610 MHz（连续 3 次）→ 低功耗卡死"],
                causes: [.lowPowerWedge],
                alert: true
            ),
            util: 96, power: 20, clock: 610
        )]
        // 1.61×20 + 95×0.20 = 51.2 W: the wall draw rides along, since the
        // compact preset always carries it.
        #expect(text(fleet) == "⚠ ● 00 96% 20W ≈51W")
    }

    @Test func memoryWarningColoursTheDotAndStaysSilent() {
        let fleet = [
            node(name: "spark-00"),
            node(name: "spark-01", health: HealthReport(
                level: .warning, reasons: ["可用内存 7.2 GB < 8（PSI 0.00，无人等内存）"], causes: [.memoryLow]
            ), availableGB: 7.2),
        ]
        // A warning changes the dot's colour and adds no words: "6 GB available" is
        // what a healthy unified-memory box serving a model looks like all day, so
        // the bar must not spend two tokens saying it forever.
        #expect(text(fleet) == "●")
    }

    /// A memory *stall* is different: PSI means work is actually waiting, and
    /// that is worth naming.
    @Test func memoryStallIsNamed() {
        let fleet = [
            node(name: "spark-00"),
            node(name: "spark-01", health: HealthReport(
                level: .critical,
                reasons: ["内存压力 PSI full avg10 0.31 > 0.25"],
                causes: [.memoryPressure],
                alert: true
            ), availableGB: 7.2),
        ]
        #expect(text(fleet) == "⚠ ● 01 内存 7G")
    }

    // MARK: - Full mode lists every machine, legibly

    /// Two machines' numbers ran together as one token (`70° C7% 01`) — reported
    /// by the user. Full mode now separates them, and CPU is gone: it was the
    /// token that made the seam ambiguous and it is a popover fact, not a bar one.
    @Test func detailedModeListsEveryMachineWithASeparator() {
        let fleet = [node(name: "spark-00"), node(name: "spark-01", util: 0, temp: 52)]
        let bar = text(fleet) { $0.mode = .detailed }
        #expect(bar == "00 12% 64° · 01 0% 52°")
        #expect(!bar.contains("C5%"))
    }

    @Test func customModeHonoursExplicitToggles() {
        let fleet = [node(name: "spark-00"), node(name: "spark-01")]
        let bar = text(fleet) {
            $0.mode = .custom
            $0.showNodeNames = true
            $0.namesOnlyWhenRelevant = false
            $0.showSpeed = false
            $0.showOnlineCount = false
            $0.showUtilization = false
        }
        #expect(bar == "00 · 01")
    }

    // MARK: - Ends of the bar

    /// The quiet default: one dot plus the fitted wall draw — the one number that
    /// still means something while nothing is happening.
    @Test func compactPresetShowsPowerByDefault() {
        let fleet = [
            node(name: "spark-00", power: 13.3),
            node(name: "spark-01", power: 11.3),
        ]
        // 1.61×13.3 + 95×0.20 = 40.4 and 1.61×11.3 + 95×0.20 = 37.2; summed = 77.6.
        #expect(text(fleet) == "● ≈78W")
    }

    @Test func powerIsFittedAndMarkedAsAnEstimate() {
        let fleet = [
            node(name: "spark-00", power: 11.8),
            node(name: "spark-01", power: 47.7),
        ]
        let bar = text(fleet) { $0.showPower = true }
        // 1.61×11.8 = 19.0 and 1.61×47.7 = 76.8, plus the 20 %-CPU prior (19 W)
        // each because these fixtures carry no CPU reading: 38.0 + 95.8 = 133.8.
        #expect(bar == "● ≈134W")
    }

    /// No GPU rail reading → no number. An estimate built on nothing would be a
    /// made-up figure in the most visible place in the app.
    @Test func powerIsOmittedWhenTheGpuRailIsUnknown() {
        let fleet = [node(name: "spark-00", power: nil)]
        #expect(text(fleet) { $0.showPower = true } == "●")
    }

    @Test func emptyFleetKeepsAClickablePlaceholder() {
        #expect(text([]) == StatusBarText.placeholder)
    }

    /// Four machines in trouble must not turn the bar into a list: two get named,
    /// the rest collapse into one token, and the fleet dot's colour already covers
    /// the remainder.
    @Test func atMostTwoDeviatingNodesAreNamed() {
        let fleet = (0..<4).map { index in
            node(
                name: String(format: "spark-%02d", index),
                health: alert(.gpuThermal, "GPU 温度 91°C ≥ 90"),
                temp: 91
            )
        }
        #expect(text(fleet) == "⚠ ● 00 91° 01 91° +2")
    }

    @Test func sshFallbackDegradesTheToneNotTheText() {
        let fleet = [node(name: "spark-00", source: .sshFallback)]
        let segments = StatusBarText.segments(for: fleet, settings: StatusBarSettings())
        #expect(segments.map(\.text) == ["●"])
        #expect(segments.first?.tone == .degraded)
    }

    // MARK: - Cause wiring (health rules -> one token)

    /// End to end: the evaluator's structured cause is what the bar renders, so
    /// a thermal alert cannot silently lose its number on the way there.
    @Test func evaluatorCausesDriveTheIndicator() {
        var evaluator = HealthEvaluator()
        var gpu = GpuSample(); gpu.tempC = 91; gpu.utilPct = 40; gpu.powerW = 90
        var system = SystemSample(); system.memAvailableBytes = 60_000_000_000
        let report = evaluator.evaluate(gpu: gpu, system: system, source: .dashboard, error: nil)
        #expect(report.causes.contains(.gpuThermal))

        let fleet = [NodeSnapshot(
            id: UUID(), name: "spark-01", host: "spark-01.local",
            source: .dashboard, gpu: gpu, system: system, health: report
        )]
        // 1.61×90 + 95×0.20 = 163.9 (the fixture carries no CPU reading).
        #expect(text(fleet) == "⚠ ● 01 91° ≈164W")
    }
}
