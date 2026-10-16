import Foundation

// The one-line menu-bar readout, as pure data so it can be unit-tested and
// previewed without a window.
//
// The rule that shapes everything here: **a token earns its width only by
// carrying a signal.** A machine's name is a constant — printing "00 01" for a
// perfectly healthy, idle pair says nothing, and it costs the most width of any
// element. So in the compact preset a node's name appears only when that node is
// the reason to look: it is down, or it is the one that tripped a health rule.
// Healthy nodes collapse to a coloured dot (the colour is the signal), and the
// numbers next to a named node are the compact form of its cause.
//
// Shape: [⚠] <dot | name+cause | name+metrics>… [▶speed] [alive/n] [≈power]

public enum StatusTone: Sendable, Equatable {
    /// Ordinary text.
    case normal
    /// Reporting and healthy — the green dot.
    case good
    /// Degraded channel (ssh fallback): not broken, not the official feed.
    case degraded
    /// Health rule tripped, but the box is working.
    case warning
    /// Needs a human: down, or an alert-level health rule.
    case critical
}

public struct StatusSegment: Sendable, Equatable {
    public var text: String
    public var tone: StatusTone

    public init(_ text: String, _ tone: StatusTone = .normal) {
        self.text = text
        self.tone = tone
    }
}

public enum StatusBarText {
    /// Empty fleet: still needs a clickable label.
    public static let placeholder = "DGX …"

    public static func segments(
        for snapshots: [NodeSnapshot],
        settings: StatusBarSettings,
        powerEstimate: PowerEstimate = PowerEstimate()
    ) -> [StatusSegment] {
        guard !snapshots.isEmpty else { return [StatusSegment(placeholder)] }
        let visible = settings.maxNodes > 0
            ? Array(snapshots.prefix(settings.maxNodes)) : snapshots
        let flags = settings.resolved
        var out: [StatusSegment] = []

        let minimal = settings.mode == .minimal

        // ⚠ is reserved for "needs attention now": a box that is down or
        // critical. Loaded-but-healthy warnings (memory tight while a model is
        // resident) show up as a coloured dot and in the popover, not as a
        // permanent ⚠ in the menu bar.
        //
        // In 极简 the single fleet glyph *becomes* the ⚠ (see below) instead of
        // being printed next to it — that preset's whole promise is one character.
        if !minimal, visible.contains(where: { $0.source == .down || $0.health.alert }) {
            out.append(StatusSegment("⚠", .critical))
        }

        // **One dot for the whole fleet.**
        //
        // This replaced "one dot per machine", which was a constant: a healthy
        // pair printed `● ●` — two identical glyphs that named neither machine and
        // said nothing, while making the bar's width grow with the fleet. A single
        // dot whose *colour* is the worst level in the fleet carries the same
        // information at a fixed cost, and the machines that actually have
        // something to say name themselves next to it (see below).
        if flags.showFleetDot {
            out.append(StatusSegment(
                minimal ? fleetGlyph(for: visible) : healthyGlyph,
                fleetTone(for: visible)
            ))
        }

        // Per-machine slots: the deviating ones always (max two, then `+N`), the
        // healthy ones only in the mode that exists to list every machine.
        let deviating = visible.filter(isDeviating)
        let named = Set(deviating.prefix(2).map(\.id))
        var metricSlots = 0

        for snapshot in visible {
            guard let slot = namedSlot(
                for: snapshot, flags: flags, mayName: named.contains(snapshot.id)
            ) else {
                guard !flags.namesOnlyWhenRelevant, flags.showNodeNames, snapshot.source != .down
                else { continue }
                // Full mode: every machine gets its numbers.
                append(StatusSegment(metricsText(for: snapshot, flags: flags), tone(for: snapshot)))
                metricSlots += 1
                continue
            }
            append(slot)
            if !flags.namesOnlyWhenRelevant { metricSlots += 1 }
        }

        /// Separator between two machines' numbers. Without it they read as one
        /// run-on token (`70° C7% 01`) — which is exactly what was reported.
        func append(_ slot: StatusSegment) {
            var slot = slot
            if metricSlots > 0, !flags.namesOnlyWhenRelevant {
                slot.text = "· " + slot.text
            }
            out.append(slot)
        }

        // Minimal is one glyph, so no "+N" either: the dot already carries the
        // fleet's worst level, and a counter would break the promise.
        if deviating.count > named.count, !minimal {
            out.append(StatusSegment("+\(deviating.count - named.count)", .critical))
        }

        // One live slot, same ladder as the deployment banner: the rate of
        // whatever is happening, falling back to the in-flight count.
        //
        // The bar used to show a rate only while decoding, which left it silent
        // through the phase a long-context box spends most of its time in — a
        // prefill produces no decode tokens, so "it is working" and "it is idle"
        // looked identical. A prefill now says so.
        if flags.showSpeed, let activity = activitySegment(for: visible) {
            out.append(activity)
        }
        if flags.showOnlineCount {
            let alive = visible.filter { $0.source != .down }.count
            if alive != visible.count {
                out.append(StatusSegment("\(alive)/\(visible.count)", .critical))
            }
        }
        if flags.showPower {
            let known = visible.compactMap { powerEstimate.wholeMachineW(gpuW: $0.gpu.powerW) }
            if !known.isEmpty {
                out.append(StatusSegment(String(format: "≈%.0fW", known.reduce(0, +))))
            }
        }
        return out
    }

    public static func text(
        for snapshots: [NodeSnapshot],
        settings: StatusBarSettings,
        powerEstimate: PowerEstimate = PowerEstimate()
    ) -> String {
        segments(for: snapshots, settings: settings, powerEstimate: powerEstimate)
            .map(\.text)
            .joined(separator: " ")
    }

    /// The in-flight slot for the bar: aggregated across the machines shown.
    ///
    /// Priority ladder, matching the deployment banner: decode rate → prefill →
    /// raw in-flight count. Only one of them is ever the answer, and silence is
    /// reserved for genuinely doing nothing.
    static func activitySegment(for visible: [NodeSnapshot]) -> StatusSegment? {
        // Only a *fatal* engine drops out of the rate ladder. A greyed
        // "▶38/s·21s" sitting next to "⚠ 引擎已崩" reads as if the box were still
        // working — measured live 2026-10-03 in the mock matrix, that is exactly
        // what it showed. An unreachable box keeps its last rate on purpose: "last
        // measured 63/s, 40 s ago" is what you want during a network drop, and the
        // age already says how stale it is.
        let measurable = visible.filter { !$0.health.causes.contains(.engineFatal) }
        let samples = measurable.compactMap(\.inference)
        guard !samples.isEmpty else { return nil }

        func state(_ sample: InferenceSample) -> SpeedDisplay.State {
            SpeedDisplay.state(rate: sample.decodeTPS, age: sample.decodeTPSAge, running: sample.running)
        }

        let decode = samples.filter { state($0) == .live }.compactMap(\.decodeTPS).reduce(0, +)
        if decode > 0.5 {
            return StatusSegment("▶\(TaskSummary.formatRate(decode))/s", .good)
        }
        // "1 in flight" and "prefilling ×1" are instantaneous claims, so only make
        // them from an observation that is still fresh. A stalled probe used to leave
        // `×1` on the bar forever — and because this slot outranks the greyed rate,
        // the bar showed "1 request in flight" while the engine was visibly decoding
        // at 38 tok/s (measured on the real fleet 2026-10-03: bar `● ● ×1` while
        // completion_tokens grew 568 333 → 568 715 with the probe wedged). When the
        // observation is old, fall through to the greyed last-known rate instead.
        func isFresh(_ sample: InferenceSample) -> Bool {
            (sample.activityAge ?? 0) <= SpeedDisplay.freshnessSeconds
        }
        let prefilling = samples.filter(isFresh).compactMap(\.prefilling).reduce(0, +)
        if prefilling > 0 { return StatusSegment("⇡×\(Int(prefilling))", .normal) }
        let running = samples.filter(isFresh).compactMap(\.running).reduce(0, +)
        if running > 0 { return StatusSegment("×\(Int(running))", .normal) }
        // Work just finished: keep the last measured rate, greyed and with its
        // age, instead of blanking the slot.
        //
        // Blanking it was the old rule ("a stale number is worse than no number"),
        // but their traffic is short requests with gaps: the rate was measured
        // often and live rarely, so the bar looked broken most of the time. Grey
        // plus "·12s" says exactly what the number is, and the eye keeps its place.
        let stoppedRates = samples
            .filter { state($0) == .stopped }
            .compactMap { sample -> (rate: Double, age: Double?)? in
                guard let rate = sample.decodeTPS else { return nil }
                return (rate, sample.decodeTPSAge)
            }
        let freshest = stoppedRates.min { ($0.age ?? .greatestFiniteMagnitude) < ($1.age ?? .greatestFiniteMagnitude) }
        if let freshest, freshest.rate > 0.5 {
            return StatusSegment(
                SpeedDisplay.compactText(rate: freshest.rate, age: freshest.age, stopped: true),
                .normal
            )
        }
        return nil
    }

    /// Does this machine have something the bar should say out loud?
    ///
    /// The bar reports on *attention*, not on *noticed*: a warning-level rule
    /// (memory tight while a model is resident, an ACPI zone 12 °C under its
    /// ceiling) colours the dot yellow and stays silent. On a unified-memory box
    /// "6 GB available" is what a healthy machine serving a model looks like all
    /// day, so naming it turned the quietest surface in the app into a permanent
    /// two-token alarm that said nothing.
    public static func isDeviating(_ snapshot: NodeSnapshot) -> Bool {
        if snapshot.source == .down || snapshot.health.alert || snapshot.health.level == .critical {
            return true
        }
        // Deliberate exception to "only alert/critical earn a name".
        //
        // The rule above exists so a machine that is simply loaded (memory tight
        // with a model resident) never turns the bar into standing noise. Waiting
        // for a password is the opposite kind of condition: it is not a load
        // pattern, it does not clear by itself, and no amount of staring at the
        // numbers reveals it — the SSH fallback keeps them all plausible. On
        // 2026-10-16 exactly that combination left the bar looking calm for hours
        // while the official channel was dead. Naming the machine is the whole fix.
        return snapshot.health.causes.contains(.needsLogin)
    }

    /// The name slot, or nil when this node should stay unnamed.
    ///
    /// In `namesOnlyWhenRelevant` mode a healthy node has no slot at all — that
    /// is the whole point. When a node does deserve its name, it also gets the
    /// compact form of *why*: a name with no number next to it is exactly the
    /// "00 01" this mode exists to remove.
    private static func namedSlot(
        for snapshot: NodeSnapshot,
        flags: StatusBarSettings,
        mayName: Bool
    ) -> StatusSegment? {
        guard flags.showNodeNames else { return nil }
        let short = shortName(snapshot.name)
        if snapshot.source == .down {
            return mayName ? StatusSegment("\(short) ✕", .critical) : nil
        }
        if flags.namesOnlyWhenRelevant {
            // Only a machine with something to report gets a name, and only the
            // first couple of them (see the budget in `segments`).
            guard mayName, isDeviating(snapshot) else { return nil }
            return StatusSegment("\(short) \(causeIndicator(for: snapshot))", tone(for: snapshot))
        }
        return StatusSegment(metricsText(for: snapshot, flags: flags), tone(for: snapshot))
    }

    /// `00 95% 70°` — the name plus whichever metrics this mode asks for.
    static func metricsText(for snapshot: NodeSnapshot, flags: StatusBarSettings) -> String {
        var slot = shortName(snapshot.name)
        if flags.showUtilization, let util = snapshot.gpu.utilPct {
            slot += String(format: " %.0f%%", util)
        }
        if flags.showTemperature, let temp = snapshot.gpu.tempC {
            slot += String(format: " %.0f°", temp)
        }
        if flags.showMemory, let mem = snapshot.gpu.memUsedPct {
            slot += String(format: " %.0f%%M", mem)
        }
        if flags.showCPU, let cpu = snapshot.system.cpuUsagePct {
            slot += String(format: " C%.0f%%", cpu)
        }
        return slot
    }

    /// The one dot that stands for the whole fleet: the worst tone across the
    /// machines the bar is showing.
    ///
    /// Worst, not first: the dot answers "do I need to look at this at all", and a
    /// fleet is as healthy as its sickest member. Reported by the user as the
    /// problem to solve — `● ●` for a healthy pair was two identical constants.
    static func fleetTone(for visible: [NodeSnapshot]) -> StatusTone {
        let order: [StatusTone] = [.normal, .good, .degraded, .warning, .critical]
        var worst = StatusTone.good
        for snapshot in visible {
            let tone = tone(for: snapshot)
            if let a = order.firstIndex(of: tone), let b = order.firstIndex(of: worst), a > b {
                worst = tone
            }
        }
        return worst
    }

    /// The single glyph 极简 shows: the fleet's state *as one character*.
    ///
    /// Every machine down is a `✕` (nothing is answering), anything at alert level
    /// is a `⚠`, and the rest is the dot whose colour carries the level. Swapping
    /// the glyph rather than appending a second token is what keeps this preset at
    /// one character wide no matter how big the fleet is.
    static func fleetGlyph(for visible: [NodeSnapshot]) -> String {
        guard !visible.isEmpty else { return "●" }
        if visible.allSatisfy({ $0.source == .down }) { return "✕" }
        if visible.contains(where: { $0.source == .down || $0.health.alert }) { return "⚠" }
        return "●"
    }

    /// The shortest honest answer to "why is this one flagged".
    ///
    /// Ordering follows how actionable the cause is at a glance: a stopped box,
    /// then the failure a green dashboard hides (the low-power wedge), then
    /// memory stalls, then thermals. Each branch prefers a number over a word so
    /// the token stays scannable.
    static func causeIndicator(for snapshot: NodeSnapshot) -> String {
        let causes = snapshot.health.causes
        if causes.contains(.unreachable) { return "✕" }
        // Placed above the numeric branches: this one has no number to show, and
        // it is the only cause whose cure is an action rather than a wait.
        if causes.contains(.needsLogin) { return "需登录" }
        if causes.contains(.engineFatal) { return "引擎已崩" }
        if causes.contains(.engineStalled) { return "停滞" }
        if causes.contains(.lowPowerWedge) {
            let util = snapshot.gpu.utilPct.map { String(format: "%.0f%%", $0) } ?? "忙"
            let power = snapshot.gpu.powerW.map { String(format: "%.0fW", $0) } ?? "低功耗"
            return "\(util) \(power)"
        }
        // Thermals: the GPU rail first (that is the one GB10 cannot self-limit),
        // then the ACPI zone the box actually throttles on.
        if causes.contains(.gpuThermal), let temp = snapshot.gpu.tempC {
            return String(format: "%.0f°", temp)
        }
        if causes.contains(.cpuThermal), let temp = snapshot.system.cpuTempC {
            return String(format: "%.0f°", temp)
        }
        if causes.contains(.memoryPressure) || causes.contains(.memoryLow) {
            if let available = snapshot.system.memAvailableBytes {
                return String(format: "内存 %.0fG", Double(available) / 1_000_000_000)
            }
            return "内存"
        }
        if causes.contains(.swap) { return "swap" }
        // No structured cause at all (a hand-built report — demo data, or a
        // probe that only produced a reason string): fall back to the numbers,
        // which are still an honest answer to "why is this one flagged".
        if let temp = snapshot.gpu.tempC, temp >= 85 {
            return String(format: "%.0f°", temp)
        }
        if let available = snapshot.system.memAvailableBytes,
            Double(available) < 16_000_000_000
        {
            return String(format: "内存 %.0fG", Double(available) / 1_000_000_000)
        }
        if let util = snapshot.gpu.utilPct, let power = snapshot.gpu.powerW,
            util >= 80, power <= 25
        {
            return String(format: "%.0f%% %.0fW", util, power)
        }
        // A warning with nothing numeric behind it: say so rather than invent a
        // reason the health rules never produced.
        return "注意"
    }

    /// The glyph for "reporting and healthy". One place, because the fleet dot, the
    /// 极简 glyph and the per-machine line all have to agree on it.
    public static let healthyGlyph = "●"

    /// Colour assignment for a node slot. Kept here (not in the AppKit layer) so
    /// the rule is testable: a green dot must never be able to mean "alarming".
    public static func tone(for snapshot: NodeSnapshot) -> StatusTone {
        switch snapshot.source {
        case .down: return .critical
        case .sshFallback: return .degraded
        case .dashboard:
            switch snapshot.health.level {
            case .ok, .unknown: return .good
            case .warning: return .warning
            case .critical: return .critical
            }
        }
    }

    /// `spark-00` -> `00`; anything else is kept as-is (a fleet of hand-named
    /// boxes must not lose its identity to a bad assumption about prefixes).
    static func shortName(_ name: String) -> String {
        name.hasPrefix("spark-") ? String(name.dropFirst("spark-".count)) : name
    }
}
