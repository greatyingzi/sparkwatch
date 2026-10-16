import Foundation
import Testing

@testable import SparkWatchCore

/// "Waiting for a password" has to be visible. It is the one degraded state whose
/// cause cannot be read off the numbers — the SSH fallback fills every figure in,
/// so without an explicit signal a node whose official channel is dead looks
/// exactly like a healthy one (2026-10-16: hours of a calm-looking menu bar).
@Suite("需登录状态的对外表达")
struct NeedsLoginSurfaceTests {
    // MARK: - Builders

    /// A healthy box: nothing but the credential rule may fire on it.
    private func healthyEvaluatorReport(awaitingCredentials: Bool, error: String?) -> HealthReport {
        var gpu = GpuSample(utilPct: 20, tempC: 60, powerW: 45)
        gpu.smClockMHz = 2400
        var system = SystemSample()
        system.memAvailableBytes = 60_000_000_000
        system.memPressureAvg10 = 0.0
        system.cpuTempC = 54
        system.thermalLimitC = 104
        var evaluator = HealthEvaluator()
        return evaluator.evaluate(
            gpu: gpu,
            system: system,
            source: .sshFallback,
            error: error,
            awaitingCredentials: awaitingCredentials
        )
    }

    private func node(awaitingCredentials: Bool, causes: [HealthCause], reasons: [String]) -> NodeSnapshot {
        NodeSnapshot(
            id: UUID(),
            name: "spark-00",
            host: "dgx-spark-00",
            source: .sshFallback,
            gpu: GpuSample(utilPct: 96, tempC: 84, powerW: 77.1),
            system: SystemSample(),
            health: HealthReport(level: .warning, reasons: reasons, causes: causes),
            awaitingCredentials: awaitingCredentials
        )
    }

    private func compactText(_ nodes: [NodeSnapshot]) -> String {
        var settings = StatusBarSettings()
        settings.mode = .custom
        settings.namesOnlyWhenRelevant = true
        settings.showNodeNames = true
        settings.showFleetDot = false
        settings.showSpeed = false
        settings.showOnlineCount = false
        return StatusBarText.text(for: nodes, settings: settings)
    }

    // MARK: - Health

    @Test func waitingForAPasswordIsAWarningWithItsOwnCause() {
        let report = healthyEvaluatorReport(
            awaitingCredentials: true, error: CredentialGate.needsLoginReason
        )
        #expect(report.level == .warning)
        #expect(report.causes == [.needsLogin])
        // Exactly once: the collector also hands the same string in as `error`, and
        // the generic branch used to echo it into a second, identical reason line.
        #expect(report.reasons == [CredentialGate.needsLoginReason])
    }

    /// Not an alarm. The bar reserves ⚠ for "a human must look at the machine now"
    /// and this rule is deliberately a named yellow, so `alert` must stay false —
    /// otherwise a box parked without a login would wear a permanent ⚠.
    @Test func waitingForAPasswordIsNotAnAlert() {
        #expect(!healthyEvaluatorReport(awaitingCredentials: true, error: nil).alert)
    }

    @Test func anOrdinaryProbeErrorKeepsItsGenericCause() {
        let report = healthyEvaluatorReport(awaitingCredentials: false, error: "ssh 超时")
        #expect(report.causes == [.other])
        #expect(report.reasons == ["ssh 超时"])
    }

    // MARK: - Menu bar

    @Test func theMenuBarNamesAMachineThatNeedsALogin() {
        let text = compactText([
            node(
                awaitingCredentials: true,
                causes: [.needsLogin],
                reasons: [CredentialGate.needsLoginReason]
            )
        ])
        #expect(text == "00 需登录")
    }

    @Test func theMenuBarStaysQuietWhenNothingNeedsALogin() {
        let text = compactText([
            node(awaitingCredentials: false, causes: [.memoryLow], reasons: ["可用内存 7.6 GB < 8"])
        ])
        #expect(!text.contains("需登录"))
    }

    /// The named slot must not drag the ⚠ along: a standing alarm teaches people
    /// to ignore the icon, which is what the whole warning-only rule protects.
    @Test func needingALoginDoesNotLightTheWarningGlyph() {
        let text = compactText([
            node(
                awaitingCredentials: true,
                causes: [.needsLogin],
                reasons: [CredentialGate.needsLoginReason]
            )
        ])
        #expect(!text.contains("⚠"))
    }

    @Test func aNodeNeedingALoginCountsAsDeviating() {
        #expect(
            StatusBarText.isDeviating(
                node(awaitingCredentials: true, causes: [.needsLogin], reasons: [])
            )
        )
    }

    @Test func theCauseTokenIsTheShortestHonestAnswer() {
        #expect(
            StatusBarText.causeIndicator(
                for: node(awaitingCredentials: true, causes: [.needsLogin], reasons: [])
            ) == "需登录"
        )
    }
}
