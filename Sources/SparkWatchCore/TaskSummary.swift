import Foundation

/// One deployment action, ready to render: the rate of whatever is happening.
///
/// A single slot with a priority ladder (decode → prefill → request count) rather
/// than three independent readouts: at 400 pt wide the banner cannot afford to
/// say "▶45/s" and "prefill ×1" and "处理中 ×2" at once, and only one of them is
/// ever the answer.
public struct TaskActivity: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case decoding
        /// A measured rate whose counter has stopped: shown greyed, as "last
        /// known" rather than "now".
        case decodingStale
        case prefilling
        case busy
    }

    public var kind: Kind
    public var text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

/// Deployment-level roll-ups, as pure functions.
///
/// These exist so the popover and the detail window cannot disagree about what a
/// deployment is doing, and so the rules are testable without a window: which
/// machines a task covers, what the aggregate rate is, what it costs, and — the
/// one that needed an engine with in-flight reporting — whether it is working
/// right now.
///
/// The rule they all follow: **a deployment-level number is shown once, above the
/// cards.** Repeating it per machine is what made the panel read as noise.
public enum TaskSummary {
    /// The machines a task covers. Matching accepts both the full node name the
    /// process table reports (`spark-00`) and a short one, because a hand-written
    /// config may name the box anything.
    public static func nodes(of task: ClusterTask, in snapshots: [NodeSnapshot]) -> [NodeSnapshot] {
        let shortNames = Set(task.nodes.map { shortNodeName($0) })
        return snapshots.filter {
            task.nodes.contains($0.name) || shortNames.contains(shortNodeName($0.name))
        }
    }

    /// Every machine name the banners cover, in both spellings — used to decide
    /// whether a card may stay quiet about its model and role.
    public static func coveredNames(in tasks: [ClusterTask]) -> Set<String> {
        var names = Set<String>()
        for task in tasks {
            for node in task.nodes {
                names.insert(node)
                names.insert(shortNodeName(node))
            }
        }
        return names
    }

    /// Deployment-wide decode rate.
    ///
    /// Summed, not averaged: in a tensor-parallel deployment only the API rank has
    /// a counter at all (the workers serve no HTTP), so the sum is the honest
    /// total and cannot double count.
    public static func decodeTPS(for task: ClusterTask, in snapshots: [NodeSnapshot]) -> Double? {
        let values = nodes(of: task, in: snapshots).compactMap(\.inference?.decodeTPS)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +)
    }

    /// Deployment-wide wall draw, from the per-machine fit.
    public static func powerW(
        for task: ClusterTask,
        in snapshots: [NodeSnapshot],
        powerEstimate: PowerEstimate
    ) -> Double? {
        let values = nodes(of: task, in: snapshots)
            .compactMap { powerEstimate.wholeMachineW(gpuW: $0.gpu.powerW) }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +)
    }

    /// What the deployment is doing when there is no decode rate to show.
    ///
    /// An engine that reports its in-flight split (TensorFold's `/health`) answers
    /// the question a token counter cannot: "busy with a prefill" or "doing
    /// nothing?" Both look like `— tok/s`, and only one of them explains a box at
    /// 96 % utilisation and 80 °C. Engines that cannot report it return nil, and
    /// the banner simply says nothing rather than guessing.
    ///
    /// One slot, one priority ladder: the rate of whatever is actually happening,
    /// falling back to the request count when a rate cannot be derived yet.
    public static func activity(for task: ClusterTask, in snapshots: [NodeSnapshot]) -> TaskActivity? {
        let samples = nodes(of: task, in: snapshots).compactMap(\.inference)
        guard !samples.isEmpty else { return nil }

        // Pick by *capability*, not by the order the snapshots happen to be in.
        // Only the API rank has an HTTP counter at all, so taking "the first
        // sample" let a headless worker shadow the rate that was really being
        // produced: the banner read 处理中 ×2 while the API rank was reporting
        // 63 tok/s. A deployment-wide ladder has to be asked across nodes.
        // Only a *fresh* rate counts as "now": a stale one is the last thing that
        // happened, and the banner's whole job is the present tense.
        let liveRates = samples.filter {
            SpeedDisplay.state(rate: $0.decodeTPS, age: $0.decodeTPSAge, running: $0.running) == .live
        }
        let rate = liveRates.compactMap(\.decodeTPS).reduce(0, +)
        if rate > 0.5 {
            // No age here: a running rate already proves progress.
            return TaskActivity(kind: .decoding, text: "▶\(formatRate(rate))/s")
        }
        // No numeric prefill rate in the banner: the engine only reports prompt
        // tokens and prefill seconds when a request *finishes*, so any figure
        // shown while prefilling would be about the previous request, not this
        // one. The live answer is the count plus how long it has been running;
        // the engine-accounted speed lives in the detail card, labelled.
        // The engine says it is decoding but no rate has been derived yet — the
        // first samples after a launch or a request start, where the counter
        // delta needs two probes. Saying "处理中 ×N" here reads as "no speed
        // available, ever"; saying so explicitly is honest and tells the user the
        // number is coming. Only engines that report their stream split can
        // distinguish this from a prefill, so it is gated on that.
        if samples.contains(where: { ($0.decoding ?? 0) > 0 && ($0.prefilling ?? 0) == 0 }) {
            return TaskActivity(kind: .decoding, text: "▶ 测量中…")
        }
        if let sample = samples.first(where: { ($0.prefilling ?? 0) > 0 }),
            let prefilling = sample.prefilling
        {
            return TaskActivity(kind: .prefilling, text: String(format: "prefill ×%.0f", prefilling) + ageSuffix(sample))
        }
        if let sample = samples.first(where: { ($0.running ?? 0) > 0 }),
            let running = sample.running
        {
            return TaskActivity(kind: .busy, text: String(format: "处理中 ×%.0f", running) + ageSuffix(sample))
        }
        // Nothing is happening right now, but something happened recently: show
        // the last measured rate greyed, with its age, instead of nothing.
        //
        // This is the case that made the display feel broken: their traffic is
        // short requests with gaps, so a rate is *measured* often but *live*
        // rarely — and dropping the number on every gap meant the speed was
        // missing most of the time it was asked for. Grey + age is honest, and
        // the number stays where the eye already is.
        let stoppedRates = samples
            .filter {
                SpeedDisplay.state(rate: $0.decodeTPS, age: $0.decodeTPSAge, running: $0.running) == .stopped
            }
            .compactMap { sample -> (rate: Double, age: Double?)? in
                guard let rate = sample.decodeTPS else { return nil }
                return (rate, sample.decodeTPSAge)
            }
        // Freshest wins: several machines can each hold a stopped reading, and the
        // one measured most recently is the least misleading.
        let freshest = stoppedRates.min { ($0.age ?? .greatestFiniteMagnitude) < ($1.age ?? .greatestFiniteMagnitude) }
        if let freshest {
            return TaskActivity(
                kind: .decodingStale,
                text: SpeedDisplay.compactText(rate: freshest.rate, age: freshest.age, stopped: true)
            )
        }
        return nil
    }

    /// " · 27s": how long the oldest request has been running.
    ///
    /// The only live progress signal during a prefill — a 20K-token prompt froze
    /// every counter for its whole duration, so "×1" with a growing age is the
    /// honest way to say "it is working, not stuck".
    static func ageSuffix(_ sample: InferenceSample) -> String {
        guard let oldest = sample.oldestSeconds, oldest >= 1 else { return "" }
        return oldest >= 60
            ? String(format: " · %.0fm", oldest / 60)
            : String(format: " · %.0fs", oldest)
    }

    /// 6200 → "6.2k": prefill rates are thousands of tokens per second and would
    /// otherwise eat the row.
    public static func formatRate(_ value: Double) -> String {
        value >= 1000
            ? String(format: "%.1fk", value / 1000)
            : String(format: "%.0f", value)
    }

    public static func shortNodeName(_ name: String) -> String {
        name.replacingOccurrences(of: "spark-", with: "")
    }
}
