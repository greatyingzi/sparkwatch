import Foundation
import Testing

@testable import SparkWatchCore

// MARK: - Power model

@Suite("整机功耗模型")
struct PowerModelTests {
    /// The anchors the coefficients were fitted to, as a regression guard. If
    /// someone "tunes" a coefficient by eye, one of these must move.
    @Test func matchesTheMeasuredFirmwareAnchors() {
        let model = PowerEstimate()
        func watts(_ gpu: Double, _ cpu: Double) -> Double {
            model.estimate(gpuW: gpu, cpuUsagePct: cpu)!.wallW
        }
        // idle, headless, 2026-01 firmware (CX7 hot-plug fix in): 22-25 W.
        #expect(watts(11, 3) >= 20 && watts(11, 3) <= 26)
        // MoE decode steady: ~45 W.
        #expect(abs(watts(15, 20) - 45) <= 6)
        // LLM inference typical: 60-90 W.
        #expect(watts(35.65, 30) >= 70 && watts(35.65, 30) <= 95)
        // 2-node TP pair, measured at the wall: 117 W per box.
        #expect(abs(watts(47.7, 40) - 117) <= 8)
        // CPU saturated, GPU idle: 120-130 W.
        #expect(watts(12, 100) >= 108 && watts(12, 100) <= 130)
        // GPU saturated: ~170 W wall.
        #expect(abs(watts(87, 20) - 170) <= 14)
    }

    @Test func isMonotoneInBothInputs() {
        let model = PowerEstimate()
        var previous = 0.0
        for gpu in stride(from: 0.0, through: 95, by: 5) {
            let value = model.estimate(gpuW: gpu, cpuUsagePct: 20)!.wallW
            #expect(value >= previous)
            previous = value
        }
        previous = 0
        for cpu in stride(from: 0.0, through: 100, by: 10) {
            let value = model.estimate(gpuW: 20, cpuUsagePct: cpu)!.wallW
            #expect(value >= previous)
            previous = value
        }
    }

    /// The 240 W number on the adapter is a rating, not a measurement: nothing
    /// reaches it (a saturated Spark lands near 180-200 W), so the model must cap
    /// at the measured ceiling rather than at the nameplate.
    @Test func capsAtTheMeasuredCeilingNotTheNameplate() {
        let model = PowerEstimate()
        #expect(model.estimate(gpuW: 200, cpuUsagePct: 100)!.wallW == model.capW)
        #expect(model.capW < 240)
        #expect(model.estimate(gpuW: 0, cpuUsagePct: 0)!.wallW == model.floorW)
    }

    /// Dynamic CPU power tracks clock, so the same utilisation at a lower clock
    /// costs less. Both clusters report separate policies, so the ratio is a mean.
    @Test func cpuFrequencyWeightsTheCpuTerm() {
        let model = PowerEstimate()
        let fast = model.estimate(gpuW: 20, cpuUsagePct: 60, cpuFreqRatio: 1.0)!.wallW
        let slow = model.estimate(gpuW: 20, cpuUsagePct: 60, cpuFreqRatio: 0.6)!.wallW
        #expect(slow < fast)
    }

    @Test func flagsLowConfidenceWhereTheModelExtrapolates() {
        let model = PowerEstimate()
        // CPU-heavy: only a single anchor covers this corner.
        #expect(model.estimate(gpuW: 12, cpuUsagePct: 90)!.confidence == .low)
        // Beyond the measured GPU range.
        #expect(model.estimate(gpuW: 95, cpuUsagePct: 20)!.confidence == .low)
        // Missing the CPU side: still a number, but labelled.
        let assumed = model.estimate(gpuW: 30, cpuUsagePct: nil)!
        #expect(assumed.cpuAssumed)
        #expect(assumed.confidence == .low)
        #expect(assumed.note?.contains("CPU") == true)
    }

    /// A settings file from the two-point era must migrate, not reset.
    @Test func migratesTheOldCoefficients() throws {
        // Untouched file (the values the old version shipped): adopt the new fit.
        let untouched = #"{"enabled":true,"baseW":12,"perGpuW":2.2,"maxW":240}"#
        let decoded = try JSONDecoder().decode(PowerEstimate.self, from: Data(untouched.utf8))
        #expect(decoded.kGpu == PowerEstimate().kGpu)
        #expect(decoded.capW <= 200)          // the nameplate cap is clamped to the measured one
        #expect(decoded.enabled)

        // Hand-tuned slope: a real instruction, kept.
        let tuned = #"{"enabled":true,"baseW":30,"perGpuW":2.0,"maxW":240}"#
        let kept = try JSONDecoder().decode(PowerEstimate.self, from: Data(tuned.utf8))
        #expect(kept.kGpu == 2.0)

        // And a partial/unknown file still loads instead of failing wholesale.
        let partial = #"{"kCpu":120}"#
        let other = try JSONDecoder().decode(PowerEstimate.self, from: Data(partial.utf8))
        #expect(other.kCpu == 120)
        #expect(other.kGpu == PowerEstimate().kGpu)
    }
}

// MARK: - Thermal stream

@Suite("2秒热遥测流")
struct ThermalStreamParserTests {
    @Test func parsesABootLine() {
        var parser = ThermalStreamParser()
        let event = parser.consume("B|4564a12c83144943993a0131cfb6b109|1259161.55|20")
        guard case let .boot(identity)? = event else {
            Issue.record("expected a boot event")
            return
        }
        #expect(identity.bootID == "4564a12c83144943993a0131cfb6b109")
        #expect(identity.uptimeSeconds == 1_259_161.55)
        #expect(identity.cpuCount == 20)
    }

    @Test func parsesASample() {
        var parser = ThermalStreamParser()
        let line = "S|1697800000000|54800 52900 54900|104800|35.14,96,60,2496,3003,0,0,0|"
            + "cpu 1000 0 500 8000 100 0 0 0 0 0|3900000 2808000"
        guard case let .sample(sample)? = parser.consume(line) else {
            Issue.record("expected a sample")
            return
        }
        #expect(sample.acpitzMaxC == 54.9)          // millidegrees, hottest zone
        #expect(sample.thermalLimitC == 104.8)      // the zone's own trip point
        #expect(sample.gpuW == 35.14)
        #expect(sample.utilPct == 96)
        #expect(sample.gpuTempC == 60)
        #expect(sample.smClockMHz == 2496)
        #expect(sample.smClockMaxMHz == 3003)
        #expect(sample.thermalSlowdown == false)
        #expect(sample.cpuUsagePct == nil)          // first sample: no delta yet
        // (3.9 GHz + 2.808 GHz) / 2
        #expect(abs((sample.cpuFreqMHz ?? 0) - 3_354) < 1)
        #expect(sample.cpuFreqMaxMHz == 3_900)
    }

    @Test func cpuUsageIsADeltaBetweenTwoSamples() {
        var parser = ThermalStreamParser()
        _ = parser.consume(
            "S|1|54000|104800|30,90,60,2400,3003,0,0,0|cpu 1000 0 500 8000 100 0 0 0 0 0|"
        )
        guard case let .sample(second)? = parser.consume(
            "S|3000|54000|104800|30,90,60,2400,3003,0,0,0|cpu 2000 0 1000 16000 100 0 0 0 0 0|"
        ) else {
            Issue.record("expected a sample")
            return
        }
        // total 9600 → 19100 (+9500), idle 8100 → 16100 (+8000) ⇒ 15.79 % busy.
        #expect(abs((second.cpuUsagePct ?? 0) - 15.79) < 0.2)
    }

    /// `[N/A]` stays nil: a zero would read as "idle", and an invented idle is the
    /// kind of number this app exists to avoid.
    @Test func unavailableFieldsStayNilAndFlagsSurvive() {
        var parser = ThermalStreamParser()
        guard case let .sample(sample)? = parser.consume(
            "S|1|54000|104800|[N/A],0,50,2496,3003,0,1,0|cpu 1 0 0 1 0 0 0 0 0 0|"
        ) else {
            Issue.record("expected a sample")
            return
        }
        #expect(sample.gpuW == nil)
        #expect(sample.utilPct == 0)
        // Raw bits, one per nvidia-smi column: hw_thermal was 1, sw_thermal 0.
        #expect(sample.hwSlowdown)
        #expect(sample.thermalSlowdown == false)
        #expect(sample.powerCapActive == false)
    }

    /// The remote loop must be a one-liner with no install and no state that
    /// outlives the session.
    @Test func remoteScriptIsReadOnlyAndPeriodic() {
        let script = ThermalStream.remoteScript(intervalSeconds: 2)
        #expect(script.contains("thermal_zone"))
        #expect(script.contains("nvidia-smi"))
        #expect(script.contains("sleep 2.0"))
        #expect(!script.contains("install"))
        #expect(!script.contains("systemctl"))
    }
}

// MARK: - Thermal trend

@Suite("热区趋势")
struct ThermalTrendTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    /// The published power-off curve: 92 → 96 °C in about 150 s.
    @Test func detectsTheDocumentedClimb() {
        var trend = ThermalTrend()
        var reading: ThermalTrend.Reading?
        for step in 0...15 {
            let at = start.addingTimeInterval(Double(step) * 10)
            let temp = 92 + 4 * (Double(step) * 10 / 150)
            reading = trend.update(at: at, tempC: min(96, temp))
        }
        let slope = reading?.slopePerMinute ?? 0
        #expect(slope > 1.2 && slope < 1.9)          // ~1.6 °C/min
    }

    @Test func aPlateauProducesNoTrend() {
        var trend = ThermalTrend()
        var reading: ThermalTrend.Reading?
        for step in 0...12 {
            reading = trend.update(at: start.addingTimeInterval(Double(step) * 20), tempC: 75)
        }
        #expect(reading == nil || abs(reading!.slopePerMinute) < 0.1)
    }

    /// One spiky sample must not read as a trend, and a short window is not enough
    /// to say anything at all.
    @Test func needsEnoughSpanAndSamples() {
        var trend = ThermalTrend()
        #expect(trend.update(at: start, tempC: 70) == nil)
        #expect(trend.update(at: start.addingTimeInterval(5), tempC: 80) == nil)
        #expect(trend.update(at: start.addingTimeInterval(10), tempC: 90) == nil)
        // 30 s of data is still below the 90 s minimum.
        #expect(trend.update(at: start.addingTimeInterval(30), tempC: 95) == nil)
    }

    /// The UI calls `snapshot()` many times a second; duplicates must not weight
    /// the newest second.
    @Test func ignoresRepeatedSamplesWithinTheGap() {
        var trend = ThermalTrend()
        _ = trend.update(at: start, tempC: 70)
        _ = trend.update(at: start.addingTimeInterval(100), tempC: 80)
        let first = trend.latest
        // Same temperature, one second later: must not add another point.
        _ = trend.update(at: start.addingTimeInterval(101), tempC: 80)
        #expect(trend.latest == first)
    }
}

// MARK: - Clock lock

@Suite("锁频检测")
struct ClockLockTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func flatLowClockReadsAsLocked() {
        var detector = ClockLockDetector()
        var state: ClockLockState = .unknown
        for step in 0...20 {
            state = detector.update(
                at: start.addingTimeInterval(Double(step) * 4),
                clockMHz: 2_172 + Double(step % 3) * 6,   // 2164…2184 MHz band
                utilPct: 95,
                thermalSlowdown: false
            )
        }
        #expect(state.isLocked)
        if case let .locked(mhz) = state { #expect(abs(mhz - 2_172) < 20) }
    }

    @Test func freeBoostReadsAsUnlocked() {
        var detector = ClockLockDetector()
        var state: ClockLockState = .unknown
        for step in 0...20 {
            state = detector.update(
                at: start.addingTimeInterval(Double(step) * 4),
                clockMHz: 2_450 + Double(step % 4) * 15,
                utilPct: 96,
                thermalSlowdown: false
            )
        }
        #expect(state == .unlocked)
    }

    /// An idle box sits near 2400 MHz whether or not a lock is applied, and a
    /// thermally throttled box drifts through the same numbers — neither may be
    /// reported as "locked".
    @Test func refusesToGuessFromIdleOrThrottledSamples() {
        var detector = ClockLockDetector()
        for step in 0...20 {
            _ = detector.update(
                at: start.addingTimeInterval(Double(step) * 4),
                clockMHz: 2_170, utilPct: 3, thermalSlowdown: false
            )
        }
        #expect(detector.update(
            at: start.addingTimeInterval(200), clockMHz: 2_170, utilPct: 3, thermalSlowdown: false
        ) == .unknown)

        var throttled = ClockLockDetector()
        var state: ClockLockState = .unknown
        for step in 0...20 {
            state = throttled.update(
                at: start.addingTimeInterval(Double(step) * 4),
                clockMHz: 2_170, utilPct: 95, thermalSlowdown: true
            )
        }
        #expect(state == .unknown)
    }
}

// MARK: - Failure signatures

@Suite("故障签名分类")
struct FaultModeTests {
    /// The load-bearing regression: **every** Spark in this fleet logs
    /// `insufficient power on the PCIe slot` four times during boot (one per
    /// ConnectX-7 function) and then runs for weeks. A rule keyed on the raw dmesg
    /// line would mark healthy boxes for RMA, so boot-time events must never match.
    @Test func bootTimePcieEventsAreNotEvidence() {
        let verdict = FaultModeClassifier.classifyHardware(
            utilPct: 2, powerW: 11.5, gpuTempC: 48, acpitzC: 54,
            thermalLimitC: 104.8, thermalSlowdown: false,
            pcieLatePowerEvents: 0, driverVersion: "580.178.04"
        )
        #expect(verdict == nil)
    }

    @Test func latePcieEventsWithPowerPinnedLowMatchTheDefect() {
        let verdict = FaultModeClassifier.classifyHardware(
            utilPct: 1, powerW: 29.0, gpuTempC: 55, acpitzC: 60,
            thermalLimitC: 104.8, thermalSlowdown: false,
            pcieLatePowerEvents: 3, driverVersion: "580.178.04"
        )
        #expect(verdict?.mode == .pciePowerDefect)
        #expect(verdict?.critical == true)
        #expect(verdict?.mode.action.contains("RMA") ?? false)
    }

    /// The 5 W bug is a 550.x defect. Telling someone to upgrade a driver that is
    /// already 580.x is worse than saying nothing.
    @Test func fiveWattBugIsOnlyReportedOnAffectedDrivers() {
        let old = FaultModeClassifier.classifyHardware(
            utilPct: 0, powerW: 5.0, gpuTempC: 40, acpitzC: 45,
            thermalLimitC: 104.8, thermalSlowdown: false,
            pcieLatePowerEvents: 0, driverVersion: "550.54.15"
        )
        #expect(old?.mode == .driverLowPower)

        let current = FaultModeClassifier.classifyHardware(
            utilPct: 0, powerW: 5.0, gpuTempC: 40, acpitzC: 45,
            thermalLimitC: 104.8, thermalSlowdown: false,
            pcieLatePowerEvents: 0, driverVersion: "580.178.04"
        )
        #expect(current == nil)
    }

    /// Thermal limiting is not a defect — the action is a clock lock / airflow, so
    /// the message must not read like a hardware failure.
    @Test func thermalSlowdownIsReportedAsALeverNotAFault() {
        let verdict = FaultModeClassifier.classifyHardware(
            utilPct: 92, powerW: 88, gpuTempC: 86, acpitzC: 93,
            thermalLimitC: 104.8, thermalSlowdown: true,
            pcieLatePowerEvents: 0, driverVersion: "580.178.04"
        )
        #expect(verdict?.mode == .thermalLimit)
        #expect(verdict?.critical == false)
        #expect(verdict?.message.contains("锁频") ?? false)
    }

    @Test func driverMajorParsing() {
        #expect(FaultModeClassifier.driverMajor("580.178.04") == 580)
        #expect(FaultModeClassifier.driverMajor("550.54.15") == 550)
        #expect(FaultModeClassifier.driverMajor(nil) == nil)
        #expect(FaultModeClassifier.driverMajor("[N/A]") == nil)
    }
}

// MARK: - Health rules on top of them

@Suite("热趋势与故障签名的健康规则")
struct ThermalHealthRuleTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func system(zone: Double, limit: Double = 104.8) -> SystemSample {
        var sample = SystemSample()
        sample.cpuTempC = zone
        sample.thermalLimitC = limit
        return sample
    }

    /// Climbing toward the ceiling must warn *before* the absolute line, otherwise
    /// the box cuts its own power first (it dies at ~96 °C on a 104.8 °C trip point).
    @Test func climbingZoneWarnsWhileStillFarFromTheTripPoint() {
        var evaluator = HealthEvaluator()
        var report = HealthReport(level: .ok, reasons: [])
        for step in 0...14 {
            let at = start.addingTimeInterval(Double(step) * 15)
            let zone = 81 + Double(step) * 0.35          // +1.4 °C/min, ending at ~86 °C
            report = evaluator.evaluate(
                gpu: GpuSample(), system: system(zone: zone),
                source: .dashboard, error: nil, at: at
            )
        }
        #expect(report.causes.contains(.thermalTrend))
        #expect(report.level == .warning)
        #expect(report.alert == false)
    }

    @Test func aPlateauStaysQuiet() {
        var evaluator = HealthEvaluator()
        var report = HealthReport(level: .ok, reasons: [])
        for step in 0...20 {
            report = evaluator.evaluate(
                gpu: GpuSample(), system: system(zone: 88),
                source: .dashboard, error: nil,
                at: start.addingTimeInterval(Double(step) * 15)
            )
        }
        #expect(!report.causes.contains(.thermalTrend))
        #expect(report.level == .ok)
    }

    /// Close to the ceiling and still climbing is the documented power-off recipe.
    @Test func climbingNearTheCeilingIsCritical() {
        var evaluator = HealthEvaluator()
        var report = HealthReport(level: .ok, reasons: [])
        for step in 0...14 {
            let at = start.addingTimeInterval(Double(step) * 15)
            report = evaluator.evaluate(
                gpu: GpuSample(), system: system(zone: 89 + Double(step) * 0.6),
                source: .dashboard, error: nil, at: at
            )
        }
        #expect(report.level == .critical)
        #expect(report.alert)
        #expect(report.causes.contains(.thermalTrend) || report.causes.contains(.cpuThermal))
    }

    @Test func faultSignatureSurfacesOnTheReport() {
        var evaluator = HealthEvaluator()
        var sample = system(zone: 60)
        sample.pcieLatePowerEvents = 2
        var gpu = GpuSample()
        gpu.utilPct = 0
        gpu.powerW = 29
        let report = evaluator.evaluate(
            gpu: gpu, system: sample, source: .dashboard, error: nil, at: start
        )
        #expect(report.faultMode == .pciePowerDefect)
        #expect(report.causes.contains(.faultMode))
        #expect(report.level == .critical)
    }
}

// MARK: - Crash forensics

@Suite("关机取证")
struct CrashForensicsTests {
    /// The fixture is this fleet's own shape (2026-10-06): 762 973 lines of log,
    /// ending on a journald memory-pressure line, with no shutdown marker.
    private let powerLossFixture = """
    ##bootid
    4564a12c83144943993a0131cfb6b109
    ##uptime
    1259161.55
    ##boots
     -1 dfef9cfc189b4a01b5c6c47bbb0b6022 Thu 2026-10-01 21:11:47 CST Tue 2026-10-06 05:17:24 CST
      0 4564a12c83144943993a0131cfb6b109 Tue 2026-10-06 05:19:08 CST Tue 2026-10-20 19:05:07 CST
    ##tail
    Oct 06 05:16:58 dgx-spark-00 systemd-journald[606]: Under memory pressure, flushing caches.
    Oct 06 05:17:24 dgx-spark-00 systemd-journald[606]: Under memory pressure, flushing caches.
    ##markers
    0
    ##panics
    0
    ##pstore
    0
    /sys/fs/pstore
    ##done
    """

    @Test func noShutdownMarkerReadsAsSuspectedPowerLoss() {
        let report = CrashForensics.parse(powerLossFixture)
        #expect(report.verdict == .powerLossSuspected)
        #expect(report.confident)                     // pstore was actually read and empty
        #expect(report.bootID == "4564a12c83144943993a0131cfb6b109")
        #expect(report.previousBootHadLog)
        #expect(report.previousBootTail.count == 2)
        #expect(report.summary.contains("疑似硬断电"))
    }

    @Test func aCleanShutdownMarkerWins() {
        let text = powerLossFixture.replacingOccurrences(of: "##markers\n0", with: "##markers\n3")
        let report = CrashForensics.parse(text)
        #expect(report.verdict == .cleanShutdown)
        #expect(report.confident)
    }

    @Test func pstoreDumpReadsAsKernelCrash() {
        let text = powerLossFixture
            .replacingOccurrences(of: "##pstore\n0\n/sys/fs/pstore", with: "##pstore\n2\n/sys/fs/pstore")
        let report = CrashForensics.parse(text)
        #expect(report.verdict == .kernelCrash)
        #expect(report.pstoreEntries == 2)
    }

    /// pstore needs root. "Could not read" must never be reported as "empty",
    /// because that would turn missing evidence into a confident verdict.
    @Test func unreadablePstoreDowngradesConfidence() {
        let text = powerLossFixture.replacingOccurrences(
            of: "##pstore\n0\n/sys/fs/pstore",
            with: "##pstore\n0\nls: cannot open directory '/sys/fs/pstore/': Permission denied"
        )
        let report = CrashForensics.parse(text)
        #expect(report.verdict == .powerLossSuspected)
        #expect(report.confident == false)
        #expect(report.pstoreEntries == nil)
        #expect(report.summary.contains("pstore 不可读"))
    }

    @Test func aRotatedJournalIsUndetermined() {
        let text = """
        ##bootid
        abc
        ##boots
        ##tail
        ##markers
        0
        ##panics
        0
        ##pstore
        0
        /sys/fs/pstore
        ##done
        """
        let report = CrashForensics.parse(text)
        #expect(report.verdict == .undetermined)
        #expect(report.confident == false)
    }

    @Test func watchdogAndPanicLinesAreSeparated() {
        let text = powerLossFixture.replacingOccurrences(of: "##panics\n0", with: "##panics\n2")
        let report = CrashForensics.parse(text)
        #expect(report.verdict == .watchdog)
    }
}

// MARK: - Slow-probe additions

@Suite("慢通道新增字段")
struct SshProbePowerFieldTests {
    /// The PCIe power counters must survive parsing — and the boot burst must land
    /// in its own bucket so the classifier can ignore it.
    @Test func parsesPciePowerCountersAndDriver() {
        let text = """
        ##driver
        580.178.04
        ##cpufreq
        2808000 3900000
        ##pciepower
        late 0
        all 4
        ##netmeta
        enp1s0f0np0|up|200000|10.0.0.1/24
        ##done
        """
        let result = SshProbe.parse(text)
        #expect(result.system.pcieLatePowerEvents == 0)
        #expect(result.system.pcieBootPowerEvents == 4)
        #expect(result.system.driverVersion == "580.178.04")
        #expect(abs((result.system.cpuFreqMHz ?? 0) - 3_354) < 1)
        #expect(result.system.cpuFreqMaxMHz == 3_900)
    }
}
