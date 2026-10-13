import Foundation
import Testing
@testable import SparkWatchCore

@Suite("解码速度的显示生命周期")
struct SpeedDisplayTests {
    // MARK: - The three states

    /// Fresh measurement: this is happening now.
    @Test func aFreshRateIsLive() {
        #expect(SpeedDisplay.state(rate: 47, age: 0) == .live)
        #expect(SpeedDisplay.state(rate: 47, age: nil) == .live)   // just computed
        #expect(SpeedDisplay.state(rate: 47, age: 5) == .live)
        #expect(SpeedDisplay.state(rate: 47, age: 12) == .live)    // at the boundary
    }

    /// The counter stopped moving: the number is still true, "live" is not.
    @Test func aStaleRateIsStoppedNotLive() {
        #expect(SpeedDisplay.state(rate: 47, age: 13) == .stopped)
        #expect(SpeedDisplay.state(rate: 47, age: 60) == .stopped)
        #expect(SpeedDisplay.state(rate: 47, age: 120) == .stopped)
    }

    /// Old enough to be history rather than status.
    @Test func anAncientRateDisappears() {
        #expect(SpeedDisplay.state(rate: 47, age: 121) == .hidden)
        #expect(SpeedDisplay.state(rate: 47, age: 3600) == .hidden)
    }

    /// An engine that says "nothing is running" is authoritative: the moment a
    /// request ends the number should go grey, even though the delta is seconds
    /// old. This is the exact case the user reported as "推理停止了但速度没降".
    @Test func nothingRunningGreysAfterAShortDwell() {
        // Deliberately asymmetric: the end of work does not blink the display.
        // A request that ends and another that starts a second later must not
        // flicker the number grey in between.
        #expect(SpeedDisplay.state(rate: 63, age: 0, running: 0) == .live)
        #expect(SpeedDisplay.state(rate: 63, age: 2, running: 0) == .live)
        #expect(SpeedDisplay.state(rate: 63, age: 5.9, running: 0) == .live)
        // Past the dwell with nothing running: now it is honest to grey it.
        #expect(SpeedDisplay.state(rate: 63, age: 6, running: 0) == .stopped)
        #expect(SpeedDisplay.state(rate: 63, age: 30, running: 0) == .stopped)
        // Still working: green.
        #expect(SpeedDisplay.state(rate: 63, age: 6, running: 2) == .live)
    }

    @Test func noRateAtAllIsHidden() {
        #expect(SpeedDisplay.state(rate: nil, age: nil) == .hidden)
        #expect(SpeedDisplay.state(rate: 0, age: 0) == .hidden)
        #expect(SpeedDisplay.state(rate: 0.2, age: 0) == .hidden)  // noise floor
    }

    // MARK: - The text

    @Test func stoppedTextCarriesTheAge() {
        #expect(SpeedDisplay.text(rate: 47, age: 0, stopped: true) == "▶47/s")
        #expect(SpeedDisplay.text(rate: 47, age: 32, stopped: true) == "▶47/s · 32秒前")
        #expect(SpeedDisplay.text(rate: 47, age: 150, stopped: true) == "▶47/s · 2分前")
        // Live text is just the rate: a running counter needs no annotation.
        #expect(SpeedDisplay.text(rate: 47, age: 3, stopped: false) == "▶47/s")
    }

    // MARK: - Whole-surface behaviour

    /// The menu bar keeps the last measured rate — greyed and stamped with its
    /// age — instead of dropping it.
    ///
    /// It used to blank the slot ("a glance surface must speak in the present
    /// tense"), which in practice meant the number was missing most of the time:
    /// their traffic is short requests with gaps, so a reading is measured often
    /// and *live* rarely. Grey + "·40s" is honest about which one it is, and the
    /// number stays where the eye already is.
    @Test func theStatusBarKeepsTheLastRateGreyedWithItsAge() {
        var node = NodeSnapshot(id: UUID(), name: "spark-00", host: "spark-a")
        var sample = InferenceSample()
        sample.decodeTPS = 63
        sample.decodeTPSAge = 0
        node.inference = sample

        let live = StatusBarText.text(for: [node], settings: StatusBarSettings())
        #expect(live.contains("▶63/s"))

        // Stopped: still there, now stamped with how long ago it was measured.
        sample.decodeTPSAge = 40          // past the freshness window
        node.inference = sample
        let stopped = StatusBarText.text(for: [node], settings: StatusBarSettings())
        #expect(stopped.contains("▶63/s·40s"))
        // …and it is grey, not the green "happening now" tone.
        let tones = StatusBarText.segments(for: [node], settings: StatusBarSettings())
        #expect(tones.first { $0.text.contains("▶") }?.tone == .normal)

        // Old enough to be history rather than status: gone.
        sample.decodeTPSAge = SpeedDisplay.expirySeconds + 10
        node.inference = sample
        #expect(!StatusBarText.text(for: [node], settings: StatusBarSettings()).contains("▶"))
    }

    /// A fatal engine must not keep a greyed rate on screen.
    ///
    /// Measured live 2026-10-03 against the mock matrix: the fatal scenario showed
    /// `⚠ 00 引擎已崩 ● ▶38/s·21s` — the bar said the engine had crashed and, two
    /// tokens later, showed a speed that was 21 s old. An unreachable box is
    /// different and keeps its rate on purpose (see the test above).
    @Test func aFatalEngineDropsTheRateFromTheBar() {
        var node = NodeSnapshot(id: UUID(), name: "spark-00", host: "spark-a")
        node.source = .dashboard          // reachable: the ✕ branch must not mask the cause
        var sample = InferenceSample()
        sample.decodeTPS = 63
        sample.decodeTPSAge = 21
        sample.engineFatal = true
        node.inference = sample
        // Health is the *only* source the bar reads for this decision — the same
        // report HealthEvaluator builds from the sample's fatal flag.
        node.health = HealthReport(
            level: .critical,
            reasons: ["推理引擎进入 fatal 状态（mock-model-32B）→ 需要重启两个 rank"],
            causes: [.engineFatal]
        )

        let bar = StatusBarText.text(for: [node], settings: StatusBarSettings())
        #expect(!bar.contains("▶"))
        #expect(bar.contains("引擎已崩"))

        // The same reading on a merely unreachable box stays, age and all.
        sample.engineFatal = false
        node.inference = sample
        node.source = .down
        node.health = HealthReport(level: .critical, reasons: ["隧道不通"], causes: [.unreachable])
        #expect(StatusBarText.text(for: [node], settings: StatusBarSettings()).contains("▶63/s·21s"))
    }

    /// A stale observation must not claim "1 request in flight".
    ///
    /// Measured on the real fleet 2026-10-03: the inference probe wedged, and the bar
    /// sat on `● ● ×1` (outranked by the rate slot) while the engine was visibly
    /// decoding — `completion_tokens_total` grew 568 333 → 568 715 with `dec=1`, and
    /// the last measured speed never got a chance to appear. The in-flight count is an
    /// instantaneous claim, so it is only allowed while the observation is fresh.
    @Test func aStaleInFlightCountDoesNotHideTheLastSpeed() {
        var node = NodeSnapshot(id: UUID(), name: "spark-00", host: "spark-a")
        var sample = InferenceSample()
        sample.running = 1
        sample.activityAge = 3                      // just probed
        node.inference = sample
        #expect(StatusBarText.text(for: [node], settings: StatusBarSettings()).contains("×1"))

        // Same sample, one minute later: the count is no longer a fact.
        sample.activityAge = 60
        node.inference = sample
        let stale = StatusBarText.text(for: [node], settings: StatusBarSettings())
        #expect(!stale.contains("×"))

        // …and if a rate was measured before the probe wedged, that is what shows.
        sample.decodeTPS = 38
        sample.decodeTPSAge = 52
        node.inference = sample
        let withRate = StatusBarText.text(for: [node], settings: StatusBarSettings())
        #expect(withRate.contains("▶38/s·52s"))
        #expect(!withRate.contains("×1"))
    }

    /// …and the banner's ladder likewise: a stopped deployment is not "decoding".
    @Test func theBannerDoesNotClaimAStoppedDeploymentIsDecoding() {
        var node = NodeSnapshot(id: UUID(), name: "spark-00", host: "spark-a")
        var sample = InferenceSample()
        sample.decodeTPS = 63
        sample.decodeTPSAge = 45
        sample.running = 0
        node.inference = sample
        let task = ClusterTask(
            id: "k", model: "m", nodes: ["spark-00"], ranks: ["spark-00": 0],
            tensorParallel: 1, nodeCount: 1, apiNode: "spark-00",
            apiURL: nil, quantization: nil, contextLength: nil
        )
        let activity = TaskSummary.activity(for: task, in: [node])
        #expect(activity?.kind != .decoding)
        // It is reported as *last known*, not as nothing at all.
        #expect(activity?.kind == .decodingStale)
        #expect(activity?.text == "▶63/s·45s")

        // While it really is decoding, the banner says so.
        sample.decodeTPSAge = 1
        sample.running = 2
        node.inference = sample
        #expect(TaskSummary.activity(for: task, in: [node])?.kind == .decoding)
    }

    /// The tracker hands out the last rate and its age, which is what makes the
    /// grey state possible instead of the number simply vanishing.
    @Test func theTrackerRemembersTheLastRateAndItsAge() {
        var tracker = TokenRateTracker()
        let t0 = Date(timeIntervalSince1970: 1000)
        #expect(tracker.update(generationTokens: 100, at: t0) == nil)   // first sample
        let rate = tracker.update(generationTokens: 200, at: t0.addingTimeInterval(5))
        #expect(rate == 20)                                            // 100 tok / 5 s
        #expect(abs((tracker.age(now: t0.addingTimeInterval(5)) ?? 99) - 0) < 0.01)
        // No growth: no new rate, but the old one is still available with its age.
        #expect(tracker.update(generationTokens: 200, at: t0.addingTimeInterval(10)) == nil)
        #expect(tracker.lastRate == 20)
        #expect(abs((tracker.age(now: t0.addingTimeInterval(10)) ?? 0) - 5) < 0.01)
    }
}
