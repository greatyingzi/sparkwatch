import Foundation

// MARK: - Configuration

/// One monitored DGX box.
///
/// `dashboardLocalPort` is the *local* end of our own SSH forward to the box's
/// 127.0.0.1:11000 — one per node, so several boxes can be watched at once
/// (the upstream apps hardcode a single 127.0.0.1:11000 and are single-box).
/// Where a machine's inference row comes from.
///
/// The app scans the box and picks a service by itself, but a scan cannot know
/// intent: an idle Ollama left over from months ago looks exactly like a live
/// endpoint, and a rank of a distributed task answers no HTTP at all. So the
/// answer is selectable rather than guessed — the scan proposes, the user
/// decides.
public enum InferenceSource: Codable, Equatable, Hashable, Sendable {
    /// Use the topology (task rank) or the first confident scan hit.
    case auto
    /// Always probe this endpoint, and say so when it fails instead of quietly
    /// showing some other service's numbers.
    case pinned(String)
    /// This machine's inference row is not interesting right now.
    case hidden

    public var pinnedURL: String? {
        if case let .pinned(url) = self { return url }
        return nil
    }

    public var isHidden: Bool { self == .hidden }
}

/// One inference service found on a machine, offered to the user as a choice.
public struct InferenceCandidate: Sendable, Equatable, Identifiable {
    public var port: Int
    /// "vllm" | "sglang" | "ollama" | "llama.cpp" | nil when only a port is known.
    public var engine: String?
    public var model: String?
    /// "0.0.0.0" (reachable) or "127.0.0.1" (loopback only).
    public var bind: String
    /// Why it is on the list, e.g. "进程 vllm serve" or "监听端口".
    public var note: String

    public var id: Int { port }
    /// Loopback-only services can only be reached through the box itself (the
    /// SSH channel runs the request there); anything bound to 0.0.0.0 is
    /// addressed at the machine, so it works directly over the LAN or tailnet.
    public func url(forHost host: String) -> String {
        isLoopbackOnly ? "http://127.0.0.1:\(port)" : "http://\(host):\(port)"
    }
    public var isLoopbackOnly: Bool { bind.hasPrefix("127.") || bind == "::1" }

    public init(
        port: Int,
        engine: String? = nil,
        model: String? = nil,
        bind: String = "0.0.0.0",
        note: String = "监听端口"
    ) {
        self.port = port
        self.engine = engine
        self.model = model
        self.bind = bind
        self.note = note
    }

    /// "8888 · vLLM · GLM-5.3" — what the picker shows.
    public var label: String {
        var parts = [":\(port)"]
        if let engine, !engine.isEmpty { parts.append(engine) }
        if let model, !model.isEmpty { parts.append(model) }
        if isLoopbackOnly { parts.append("仅本机") }
        return parts.joined(separator: " · ")
    }
}

public struct NodeConfig: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var sshHost: String
    public var sshUser: String
    public var dashboardLocalPort: Int
    /// Optional OpenAI/Prometheus metrics base, e.g. `http://100.64.0.1:18300`.
    /// Scraped directly over the tailnet — no tunnel, no credentials.
    public var inferenceMetricsURL: String?
    /// `auto` (probe the endpoint) or a fixed engine label. Kept as a string so
    /// hand-written config files stay readable.
    public var inferenceEngine: String = "auto"
    /// Which inference service to show. `.auto` keeps the previous behaviour
    /// (task topology, then the best scan hit); `.pinned` and `.hidden` are the
    /// user overruling the scan.
    public var inferenceSource: InferenceSource = .auto
    /// Look for an inference endpoint on the box by itself: once on first start
    /// when none is configured, and again if the configured one stops answering.
    /// Ports move (vLLM 8000 vs a container mapping 18300), and finding them by
    /// hand is exactly the chore this app is supposed to remove.
    public var autoDiscover: Bool = true
    public var enabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        sshHost: String,
        sshUser: String = NSUserName(),
        dashboardLocalPort: Int = 19100,
        inferenceMetricsURL: String? = nil,
        inferenceEngine: String = "auto",
        autoDiscover: Bool = true,
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.sshHost = sshHost
        self.sshUser = sshUser
        self.dashboardLocalPort = dashboardLocalPort
        self.inferenceMetricsURL = inferenceMetricsURL
        self.inferenceEngine = inferenceEngine
        self.autoDiscover = autoDiscover
        self.enabled = enabled
    }

    /// Tolerant decoding: a config file written by an older build (or by hand)
    /// must not break, so every field falls back to a default instead of making
    /// the whole document fail to decode. Silent fallback to built-in defaults
    /// is the worst failure mode here — the app looks configured but monitors
    /// the wrong things.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? "node"
        self.sshHost = try container.decodeIfPresent(String.self, forKey: .sshHost) ?? ""
        self.sshUser = try container.decodeIfPresent(String.self, forKey: .sshUser) ?? NSUserName()
        self.dashboardLocalPort = try container.decodeIfPresent(Int.self, forKey: .dashboardLocalPort) ?? 19100
        self.inferenceMetricsURL = try container.decodeIfPresent(String.self, forKey: .inferenceMetricsURL)
        self.inferenceEngine = try container.decodeIfPresent(String.self, forKey: .inferenceEngine) ?? "auto"
        self.inferenceSource = try container.decodeIfPresent(
            InferenceSource.self, forKey: .inferenceSource
        ) ?? .auto
        self.autoDiscover = try container.decodeIfPresent(Bool.self, forKey: .autoDiscover) ?? true
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    /// Defaults matching the two boxes this app was built against.
    ///
    /// The UUIDs are *fixed on purpose*: they are the session-store keys,
    /// so regenerating them per launch silently orphans stored tokens (the app
    /// then looks logged out even though a valid 14-day JWT is on disk — this
    /// happened during development and cost a debugging round).
    public static var defaults: [NodeConfig] {
        [
            NodeConfig(
                id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A0")!,
                name: "spark-00",
                sshHost: "spark-a",
                dashboardLocalPort: 19100,
                inferenceMetricsURL: "http://100.64.0.10:18300"
            ),
            NodeConfig(
                id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!,
                name: "spark-01",
                sshHost: "spark-b",
                dashboardLocalPort: 19101,
                inferenceMetricsURL: nil
            ),
        ]
    }
}

/// What the menu bar shows. The default has to survive being read dozens of
/// times a day, so it is deliberately short and only gets loud when something
/// is wrong — the full readout is one click away.
public struct StatusBarSettings: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable, CaseIterable {
        /// Just health dots (one per node) plus the live decode rate.
        case compact
        /// Dots + per-node utilisation and temperature.
        case detailed
        /// Dots only. Nothing else, ever.
        case minimal
        /// Whatever the toggles below say.
        case custom

        public var label: String {
            switch self {
            case .compact: "精简"
            case .detailed: "详细"
            case .minimal: "极简"
            case .custom: "自定义"
            }
        }
    }

    public var mode: Mode = .compact
    public var showNodeNames = true
    /// Names, but only for nodes that have something to report (down, or a
    /// health rule tripped). A healthy node is a coloured dot instead.
    ///
    /// This is what makes the compact preset worth reading: a machine's name is
    /// a constant, so printing "00 01" for a healthy idle pair spends the most
    /// width in the bar to say nothing. Defaults to `false` so an existing
    /// custom configuration keeps exactly the elements it asked for.
    public var namesOnlyWhenRelevant = false
    /// One status dot for the whole fleet, coloured by the worst machine — instead
    /// of one dot per machine.
    ///
    /// The per-machine dots were a constant: `● ●` for a healthy pair said nothing
    /// about either machine while making the bar wider with every machine added.
    /// A single dot at a fixed cost carries the same signal, and the machines that
    /// deviate name themselves beside it. Defaults to `false` so an existing custom
    /// configuration is unchanged; the two compact presets turn it on.
    public var showFleetDot = false
    public var showUtilization = true
    public var showTemperature = false
    public var showMemory = false
    /// Aggregate CPU usage next to the GPU figure — "everything is busy" is a
    /// different story from "the GPU is busy".
    public var showCPU = false
    public var showSpeed = true
    public var showOnlineCount = true
    /// Fitted whole-machine watts (`≈118W`). The number is a model, not a
    /// measurement — see `PowerEstimate` for the two wall-meter anchors it is
    /// solved from.
    public var showPower = false
    /// Cap on how many node slots are rendered in the bar (0 = all).
    public var maxNodes = 0

    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.mode = try container.decodeIfPresent(Mode.self, forKey: .mode) ?? .compact
        self.showNodeNames = try container.decodeIfPresent(Bool.self, forKey: .showNodeNames) ?? true
        self.namesOnlyWhenRelevant = try container.decodeIfPresent(
            Bool.self, forKey: .namesOnlyWhenRelevant
        ) ?? false
        self.showFleetDot = try container.decodeIfPresent(
            Bool.self, forKey: .showFleetDot
        ) ?? false
        self.showUtilization = try container.decodeIfPresent(Bool.self, forKey: .showUtilization) ?? true
        self.showTemperature = try container.decodeIfPresent(Bool.self, forKey: .showTemperature) ?? false
        self.showMemory = try container.decodeIfPresent(Bool.self, forKey: .showMemory) ?? false
        self.showCPU = try container.decodeIfPresent(Bool.self, forKey: .showCPU) ?? false
        self.showSpeed = try container.decodeIfPresent(Bool.self, forKey: .showSpeed) ?? true
        self.showOnlineCount = try container.decodeIfPresent(Bool.self, forKey: .showOnlineCount) ?? true
        self.showPower = try container.decodeIfPresent(Bool.self, forKey: .showPower) ?? false
        self.maxNodes = try container.decodeIfPresent(Int.self, forKey: .maxNodes) ?? 0
    }

    /// Resolve the preset into concrete flags, so the renderer has one path.
    public var resolved: StatusBarSettings {
        var settings = self
        switch mode {
        case .minimal:
            settings.showNodeNames = false
            settings.namesOnlyWhenRelevant = false
            settings.showFleetDot = true
            settings.showUtilization = false
            settings.showTemperature = false
            settings.showMemory = false
            settings.showCPU = false
            settings.showSpeed = false
            settings.showOnlineCount = false
            settings.showPower = false
        case .compact:
            // Names are allowed, but they have to earn the space: only a node
            // that is down or alerting gets one. Everything else is the fleet dot
            // plus whatever is actually moving.
            settings.showNodeNames = true
            settings.namesOnlyWhenRelevant = true
            settings.showFleetDot = true
            settings.showUtilization = false
            settings.showTemperature = false
            settings.showMemory = false
            settings.showCPU = false
            settings.showSpeed = true
            settings.showOnlineCount = true
            // On by default: with everything quiet the bar would otherwise show
            // nothing but the dot, and the fitted whole-machine watts are the one
            // number that is meaningful while nothing is happening.
            settings.showPower = true
        case .detailed:
            settings.showNodeNames = true
            settings.namesOnlyWhenRelevant = false
            // No fleet dot here: this preset exists to list every machine, so the
            // per-machine tones already carry what the dot would say.
            settings.showFleetDot = false
            settings.showUtilization = true
            settings.showTemperature = true
            settings.showMemory = false
            // CPU is off: it was the token that made two machines read as one
            // run-on number (`70° C7% 01`), and per-core load is a popover fact,
            // not a menu-bar one. Available in 自定义 for anyone who wants it.
            settings.showCPU = false
            settings.showSpeed = true
            settings.showOnlineCount = true
        case .custom:
            break
        }
        return settings
    }
}

// `PowerEstimate` (whole-machine watts) lives in PowerModel.swift: one formula
// for every surface — the cards, the menu bar, the fleet pages and the energy
// ledger. It used to be defined here while the ledger carried a second, hard-coded
// model of its own.

public struct AppSettings: Codable, Sendable {

    /// Hardware stream cadence. The dashboard pushes at ~1 Hz; we sample slower.
    public var sampleIntervalSeconds: Double = 2
    /// The expensive channel (SSH: meminfo, disk, docker, pressure) cadence.
    public var slowProbeIntervalSeconds: Double = 60
    public var nodes: [NodeConfig] = NodeConfig.defaults
    public var statusBar = StatusBarSettings()
    public var powerEstimate = PowerEstimate()
    /// Which palette to paint with. `system` follows the Mac's light/dark
    /// setting, which is what every other menu-bar app does; the four explicit
    /// themes exist for the same reason a code editor ships more than one.
    public var appearance: AppTheme = .system
    /// Power display smoothing window, in seconds. 0 disables it. The default of
    /// 8 s comes from measurement, not taste: on a TP pair the raw reading
    /// oscillates with a ~2-4 s period (burst, wait for peer, burst), so a window
    /// shorter than that just resonates with it. 8 s cut adjacent-sample jumps
    /// from 9.4 W to 1.7 W on this pair (see TimeWindowMean).
    public var powerWindowSeconds: Double = 8

    public init() {}

    /// Same tolerance as `NodeConfig`: a hand-written or older file must not
    /// fail wholesale. A missing `nodes` key means "no machines configured yet"
    /// (the settings window then opens on first run), not "use my defaults".
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sampleIntervalSeconds = try container.decodeIfPresent(
            Double.self, forKey: .sampleIntervalSeconds
        ) ?? 2
        self.slowProbeIntervalSeconds = try container.decodeIfPresent(
            Double.self, forKey: .slowProbeIntervalSeconds
        ) ?? 60
        self.nodes = try container.decodeIfPresent([NodeConfig].self, forKey: .nodes) ?? []
        self.statusBar = try container.decodeIfPresent(
            StatusBarSettings.self, forKey: .statusBar
        ) ?? StatusBarSettings()
        self.powerEstimate = try container.decodeIfPresent(
            PowerEstimate.self, forKey: .powerEstimate
        ) ?? PowerEstimate()
        self.appearance = try container.decodeIfPresent(
            AppTheme.self, forKey: .appearance
        ) ?? .system
        self.powerWindowSeconds = try container.decodeIfPresent(
            Double.self, forKey: .powerWindowSeconds
        ) ?? 8
    }
}

// MARK: - Samples

/// Where a node's numbers came from. A silent downgrade must never be mistaken
/// for a healthy official feed.
public enum DataSource: String, Sendable {
    case dashboard
    case sshFallback
    case down

    public var label: String {
        switch self {
        case .dashboard: "dash"
        case .sshFallback: "ssh"
        case .down: "down"
        }
    }
}

/// Hardware sample, normalized to bytes.
///
/// GB10-specific rules baked in:
///  * `nvidia-smi` reports `memory.used/total = [N/A]` on unified memory, so
///    memory never comes from it — it comes from the dashboard stream or
///    `/proc/meminfo`.
///  * `power_limit_in_w`, `gpu_memory_in_use_in_mb` and `cpu_memory_in_use_in_mb`
///    are constant 0 on GB10 (verified with a 104 GB vLLM resident) and are
///    deliberately not modelled.
public struct GpuSample: Sendable, Equatable {
    /// The latest raw sample, before smoothing — what the mean is a mean *of*.
    /// Kept so a smoothed figure can always be checked against reality.
    public var powerInstantW: Double?
    /// SM clock from the slow channel. The one signal that separates a real
    /// low-power wedge from "busy" on a distributed deployment: a wedged GPU has
    /// collapsed clocks, while a TP rank waiting on its peer link sits at high
    /// utilisation with normal clocks and low power — that is the collective
    /// waiting, not a fault.
    public var smClockMHz: Double?
    public var utilPct: Double?
    public var tempC: Double?
    public var powerW: Double?
    /// `[N/A]` on GB10 — the GPU rail exposes no limit of its own, which is why
    /// the health rules use absolute numbers for temperature and relative ones
    /// for the ACPI zones.
    public var powerLimitW: Double?
    /// Clock-throttle reason bits. The only signal that separates "busy" from
    /// "crippled": high utilisation with a collapsed clock is a wedge.
    public var throttle: ThrottleInfo?
    public var memTotalBytes: UInt64?
    public var memUsedBytes: UInt64?

    public init(
        utilPct: Double? = nil,
        tempC: Double? = nil,
        powerW: Double? = nil,
        memTotalBytes: UInt64? = nil,
        memUsedBytes: UInt64? = nil
    ) {
        self.utilPct = utilPct
        self.tempC = tempC
        self.powerW = powerW
        self.memTotalBytes = memTotalBytes
        self.memUsedBytes = memUsedBytes
    }

    public var memUsedPct: Double? {
        guard let used = memUsedBytes, let total = memTotalBytes, total > 0 else { return nil }
        return Double(used) * 100 / Double(total)
    }
}

public struct InferenceSample: Sendable, Equatable {
    public var engine: String?
    public var model: String?
    public var endpoint: String?
    public var running: Double?
    public var waiting: Double?
    /// Decode speed from the generation-token counter delta. Nil while idle —
    /// the UI greys it out instead of showing a decaying average.
    public var decodeTPS: Double?
    /// Prefill speed, from the engine's own accounting: newly computed prompt
    /// tokens (prompt − cached) per second of prefill work, over the requests that
    /// finished since the last sample.
    ///
    /// It is *not* a wall-clock delta, and it is not live: prompt tokens and
    /// prefill seconds only move when a request completes. That is why the UI
    /// labels it as the last finished prompt, while live progress during a prefill
    /// comes from the in-flight count and its age.
    public var prefillTPS: Double?
    public var promptTokens: Double?
    /// Engine-accounted prefill time, in seconds. Moves only when a request
    /// finishes, which is why it is paired with `promptTokens`/`cachedTokens` by
    /// `PrefillRateTracker` instead of being sampled on the wall clock.
    public var prefillSeconds: Double?
    public var generationTokens: Double?
    public var requestsProcessed: Double?
    /// Engine-specific extras. All optional: whichever the engine actually
    /// exposes gets shown, and the rest stay absent instead of rendering zeros.
    public var kvUsagePct: Double?
    public var acceptancePct: Double?
    public var vramBytes: UInt64?
    public var loadedModels: Int?
    public var quantization: String?
    public var architecture: String?
    public var contextLength: Int?
    public var parameterCount: Double?
    /// What this engine can report at all — drives the UI's wording when a
    /// metric is structurally unavailable rather than momentarily missing.
    public var capabilities = EngineCapabilities()
    /// Cumulative decode seconds reported by the engine, when it counts them.
    /// Kept on the sample so the rate can be derived from engine time instead of
    /// wall time.
    public var decodeSeconds: Double?
    /// Seconds since `decodeTPS` was measured. Nil means it was computed in this
    /// cycle (live). Set to a growing number once the counter stops moving, so
    /// the UI can grey the value instead of presenting it as current.
    public var decodeTPSAge: Double?
    /// Seconds since the last probe of this endpoint *answered* — i.e. how old this
    /// whole observation is.
    ///
    /// Distinct from `decodeTPSAge` on purpose: a busy box that is only prefilling
    /// has a very old rate but a completely fresh observation, and the two must not
    /// be confused. The instantaneous counters (`running`, `prefilling`) may only be
    /// shown while this is small: a stalled probe used to leave "×1" on the menu bar
    /// forever while the engine was visibly decoding at 38 tok/s (measured on the
    /// real fleet 2026-10-03), and that slot outranks the greyed rate, so the last
    /// known speed never got a chance to show.
    public var activityAge: Double?
    /// Set when this node is one rank of a distributed task: e.g.
    /// "rank 1 · headless worker". A worker serves the task's model but owns no
    /// endpoint, which is why the row is filled from the deployment topology
    /// rather than from probing this box's ports.
    public var taskRole: String?

    // MARK: - In-flight state (TensorFold reports it; vLLM's counters do not)
    //
    // The distinction these exist for: "busy with a 300K-token prefill" and
    // "completely idle" look identical through a decode-token counter — both show
    // no tokens/s — while one of them explains a box sitting at 96 % utilisation
    // and 80 °C. An engine that reports split streams can tell them apart.

    /// Completions currently prefilling.
    public var prefilling: Double?
    /// Completions currently decoding.
    public var decoding: Double?
    /// Prompt tokens served from the prefix cache instead of being recomputed.
    /// With `promptTokens` this gives the cache hit rate, which is the number
    /// that predicts prefill cost on agentic traffic.
    public var cachedTokens: Double?
    /// Latency percentiles from the engine's own histograms, when it exports them.
    ///
    /// A mean hides the tail, and on a 1M-context engine the tail is the whole
    /// story: measured on this fleet, TTFT p95 is ≈31 s while the request-latency
    /// p95 falls beyond the exported buckets. Both are optional, and the panel
    /// omits a tile rather than showing a zero.
    public var ttftMeanSeconds: Double?
    public var ttftP95Seconds: Double?
    public var e2eP95Seconds: Double?
    public var itlP95Seconds: Double?
    /// Share of prompt tokens that came from the prefix cache. On agentic
    /// traffic this is the difference between a 300K prefill and a few hundred
    /// tokens of work.
    public var cacheHitPct: Double?
    /// The engine has raised and wants both ranks restarted. The counters keep
    /// looking plausible, which is exactly why it is a separate flag.
    public var engineFatal: Bool = false
    /// Requests running past the engine's own stall threshold.
    public var stalledRequests: Double?
    /// Age of the oldest in-flight request, in seconds. This is the only figure
    /// that keeps moving during a *prefill*: TensorFold updates
    /// `prompt_tokens_total` and `prefill_seconds_total` only when a request
    /// finishes (measured: frozen for the whole 6 s prefill of a 20K prompt, then
    /// jumping once), so progress during prompt processing has to come from here.
    public var oldestSeconds: Double?
    /// *How* the sample was fetched, when that is worth knowing: a loopback-only
    /// engine is read through the SSH channel instead of directly. This is a
    /// transport fact, not a failure — it used to be recorded in `inferenceError`,
    /// which made a perfectly healthy deployment read as "端点无响应" in every
    /// dump.
    public var transportNote: String?

    public init() {}

    public var isActive: Bool { (decodeTPS ?? 0) > 0.5 }
}

public struct ContainerInfo: Sendable, Equatable {
    public var name: String
    public var image: String
    public var ports: String

    public init(name: String, image: String, ports: String) {
        self.name = name
        self.image = image
        self.ports = ports
    }
}

/// One block device's throughput, from two `/sys/block/<dev>/stat` reads 1 s
/// apart (the delta is taken inside the same SSH call, because the probe is
/// stateless).
public struct DiskThroughput: Sendable, Equatable {
    public var device: String
    public var readBytesPerSec: Double
    public var writeBytesPerSec: Double

    public init(device: String, readBytesPerSec: Double, writeBytesPerSec: Double) {
        self.device = device
        self.readBytesPerSec = readBytesPerSec
        self.writeBytesPerSec = writeBytesPerSec
    }
}

/// One network interface's rate, from two `/proc/net/dev` reads.
///
/// Virtual interfaces (`docker*`, `veth*`, `br-*`, `tailscale0`, `lo`) are
/// dropped: their bytes are the *same* bytes counted again on the physical
/// interface, so including them makes a 1 GB/s link look like two.
public struct NetworkInterface: Sendable, Equatable {
    public var name: String
    public var rxBytesPerSec: Double
    public var txBytesPerSec: Double
    public var ip: String?
    public var linkSpeedMbps: Double?
    public var operstate: String?

    public init(
        name: String,
        rxBytesPerSec: Double,
        txBytesPerSec: Double,
        ip: String? = nil,
        linkSpeedMbps: Double? = nil,
        operstate: String? = nil
    ) {
        self.name = name
        self.rxBytesPerSec = rxBytesPerSec
        self.txBytesPerSec = txBytesPerSec
        self.ip = ip
        self.linkSpeedMbps = linkSpeedMbps
        self.operstate = operstate
    }

    public var isUp: Bool { operstate == nil || operstate == "up" || operstate == "unknown" }
}

public struct NetworkSample: Sendable, Equatable {
    /// The interface carrying the default route.
    public var primary: String?
    public var interfaces: [NetworkInterface] = []

    public init() {}

    public var primaryInterface: NetworkInterface? {
        guard let primary else { return interfaces.first }
        return interfaces.first { $0.name == primary } ?? interfaces.first
    }

    /// Fleet-level rates across the physical interfaces only.
    public var totalRxBytesPerSec: Double { interfaces.reduce(0) { $0 + $1.rxBytesPerSec } }
    public var totalTxBytesPerSec: Double { interfaces.reduce(0) { $0 + $1.txBytesPerSec } }

    /// A monitor is looking for "is this machine's link saturated", so the
    /// interesting figure is the busiest interface, not the sum.
    public var busiest: NetworkInterface? {
        interfaces.max { ($0.rxBytesPerSec + $0.txBytesPerSec) < ($1.rxBytesPerSec + $1.txBytesPerSec) }
    }
}

/// One process holding GPU memory (top 5 by allocation).
public struct GpuProcessInfo: Sendable, Equatable, Identifiable {
    public var pid: Int
    public var name: String
    public var memoryBytes: UInt64

    public var id: Int { pid }

    public init(pid: Int, name: String, memoryBytes: UInt64) {
        self.pid = pid
        self.name = name
        self.memoryBytes = memoryBytes
    }
}

/// Why the GPU's clocks are not where you would expect them.
///
/// Exists because `utilization.gpu` says a kernel was *resident*, not that work
/// is being done: on a tensor-parallel pair a rank waiting for its peer reads
/// 90 %+ while drawing ~20 W. The distinguishing signal is a collapsed clock,
/// and the reason bits say which one — thermal, hardware, or a power cap.
public struct ThrottleInfo: Sendable, Equatable {
    public var thermal: Bool
    public var hardware: Bool
    public var powerCap: Bool
    public var smClockMHz: Double?
    public var smClockMaxMHz: Double?

    public init(
        thermal: Bool = false,
        hardware: Bool = false,
        powerCap: Bool = false,
        smClockMHz: Double? = nil,
        smClockMaxMHz: Double? = nil
    ) {
        self.thermal = thermal
        self.hardware = hardware
        self.powerCap = powerCap
        self.smClockMHz = smClockMHz
        self.smClockMaxMHz = smClockMaxMHz
    }

    public var active: Bool { thermal || hardware || powerCap }

    /// GB10 declares no slowdown/shutdown limit of its own (`tlimit` returns 4,
    /// every limit is `[N/A]`), so a power cap is not an alarm — it is the
    /// normal way a Spark stays inside its 240 W adapter.
    public var smClockPct: Double? {
        guard let smClockMHz, let smClockMaxMHz, smClockMaxMHz > 0 else { return nil }
        return min(100, smClockMHz / smClockMaxMHz * 100)
    }

    public var label: String {
        var parts: [String] = []
        if thermal { parts.append("热降频") }
        if hardware { parts.append("硬件降频") }
        if powerCap { parts.append("功耗帽") }
        return parts.isEmpty ? "无降频" : parts.joined(separator: " · ")
    }
}

/// Kernel-level GPU/memory incidents since boot. Counters only — the app never
/// reads the log bodies, so nothing user-specific leaves the box.
public struct KernelErrors: Sendable, Equatable {
    /// False when the kernel log could not be read at all (no permission, no
    /// `dmesg`, no journal). A monitor that cannot tell "no incidents" from
    /// "cannot look" will report a clean bill of health it has no basis for.
    public var available: Bool
    public var xid: Int
    public var oomKills: Int
    public var nvErrNoMemory: Int

    public init(available: Bool = false, xid: Int = 0, oomKills: Int = 0, nvErrNoMemory: Int = 0) {
        self.available = available
        self.xid = xid
        self.oomKills = oomKills
        self.nvErrNoMemory = nvErrNoMemory
    }

    public var isClean: Bool { available && xid == 0 && oomKills == 0 && nvErrNoMemory == 0 }
}

/// The node's own view of the tailnet.
///
/// Read on the node (`tailscale status --json`), never inferred from this Mac's
/// peer list: "this machine left the tailnet" and "I cannot see this machine"
/// are different problems, and conflating them sends you debugging the wrong end.
public struct TailnetInfo: Sendable, Equatable {
    public var available: Bool
    public var online: Bool
    public var ip: String?
    public var relay: String?
    public var keyExpired: Bool
    public var version: String?

    public init(
        available: Bool = false,
        online: Bool = false,
        ip: String? = nil,
        relay: String? = nil,
        keyExpired: Bool = false,
        version: String? = nil
    ) {
        self.available = available
        self.online = online
        self.ip = ip
        self.relay = relay
        self.keyExpired = keyExpired
        self.version = version
    }

    /// `nil` relay means a direct path; the literal "DERP" names a relay.
    public var pathLabel: String {
        guard let relay, !relay.isEmpty, relay != "DERP" else { return "直连" }
        return relay
    }
}

public struct SystemSample: Sendable, Equatable {
    public var load1: Double?
    public var memTotalBytes: UInt64?
    public var memAvailableBytes: UInt64?
    public var memFreeBytes: UInt64?
    /// Page cache + buffers + reclaimable slab. On GB10 the page cache and CUDA
    /// share one unified pool, so cache pressure is real pressure.
    public var memCacheBytes: UInt64?
    /// `/proc/pressure/memory` avg10 — "it did not fit" shows up here long
    /// before it shows up as swap.
    public var memPressureAvg10: Double?
    public var diskTotalBytes: UInt64?
    public var diskUsedBytes: UInt64?
    public var swapTotalBytes: UInt64?
    public var swapFreeBytes: UInt64?
    public var uptimeSeconds: Double?
    /// Aggregate CPU usage over the probe's own 1 s sampling window, plus the
    /// hottest thermal zone (which is what a Spark actually throttles on).
    public var cpuUsagePct: Double?
    public var cpuTempC: Double?
    /// Mean of the CPU policy clocks (GB10: 3.9 GHz performance cluster +
    /// 2.808 GHz efficiency cluster). Used to weight the power model's CPU term:
    /// dynamic power tracks clock, so 50 % busy at 2.8 GHz is not 50 % busy at
    /// 3.9 GHz. Filled by the fast thermal stream, never by the slow probe.
    public var cpuFreqMHz: Double?
    public var cpuFreqMaxMHz: Double?
    /// The platform's own declared ceiling for that thermal zone (its ACPI trip
    /// point, 104 °C on GB10). Thresholds are computed *relative* to it: a fixed
    /// 90 °C line turned a normal load-time reading into a permanent ⚠, because
    /// the hardware itself considers 104 the limit.
    public var thermalLimitC: Double?
    /// Kernel version of the running driver (`580.178.04`). Only used to decide
    /// whether the 5 W low-power bug's advice ("upgrade to 580.x") makes sense.
    public var driverVersion: String?
    /// `insufficient power on the PCIe slot` events **more than 180 s after boot**.
    ///
    /// Every Spark here logs that line four times during boot (one per ConnectX-7
    /// function) and then runs fine for weeks, so the boot-time burst is not
    /// evidence of anything. A late occurrence — together with power pinned near
    /// 30 W at 0 % utilisation — is the documented power-delivery defect.
    public var pcieLatePowerEvents: Int?
    public var pcieBootPowerEvents: Int?
    public var cpuCores: Int?
    public var containers: [ContainerInfo] = []
    /// Root block device throughput, from two `/sys/block/<dev>/stat` reads
    /// inside one SSH call.
    public var diskReadBytesPerSec: Double?
    public var diskWriteBytesPerSec: Double?
    /// Physical interfaces only: `docker*`/`veth*`/`tailscale0` carry the *same*
    /// bytes as the link underneath them, so counting them would report a
    /// gigabit link as two.
    public var network = NetworkSample()
    /// GPU-side allocation, summed from `nvidia-smi --query-compute-apps`.
    ///
    /// On unified memory this is the only honest answer to "how much of the pool
    /// is the model holding": `--query-gpu=memory.used` returns `[N/A]`, and
    /// `MemTotal − MemAvailable` is the whole system rather than the GPU's share.
    public var gpuAllocBytes: UInt64?
    /// Top GPU-memory holders, by PID. Answers the question a percentage cannot:
    /// *which* process is holding the pool.
    public var gpuProcesses: [GpuProcessInfo] = []
    public var kernelErrors = KernelErrors()
    /// True while a kernel counter has **risen** since the previous probe. The
    /// collector computes it from probe-to-probe deltas and clears it after an
    /// hour — "since boot" counters cannot be judged directly, because a single
    /// Xid from last week would keep the box in alarm forever.
    public var incidentActive = false
    /// The node's own tailnet state (read on the node, not inferred from here).
    public var tailnet: TailnetInfo?

    public init() {}

    public var swapUsedBytes: UInt64? {
        guard let total = swapTotalBytes, let free = swapFreeBytes, total >= free else { return nil }
        return total - free
    }

    public var memUsedPct: Double? {
        guard let total = memTotalBytes, let available = memAvailableBytes, total > 0 else {
            return nil
        }
        return Double(total - available) * 100 / Double(total)
    }

    /// The unified pool split by **who** holds it — the figure a single
    /// occupancy bar cannot express. Any piece may be `nil` (unknown), and the
    /// UI drops that segment rather than drawing a zero.
    public func memorySplit() -> (gpu: UInt64?, system: UInt64?, free: UInt64?) {
        let used = memTotalBytes.flatMap { total in memAvailableBytes.map { total - $0 } }
        let gpu = gpuAllocBytes
        let system = used.map { whole in gpu.map { whole > $0 ? whole - $0 : 0 } ?? whole }
        return (gpu, system, memAvailableBytes)
    }
}

/// Reconciled truth for one box in one tick.
public struct NodeSnapshot: Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var host: String
    public var source: DataSource
    public var gpu: GpuSample
    public var system: SystemSample
    public var inference: InferenceSample?
    /// What the node is actually running, read from its process table (slow
    /// channel). This is what makes a distributed deployment legible: a rank-1
    /// worker has no API of its own, and its `--served-model-name` is the honest
    /// answer to "what is this box doing", not whatever its stale port replies.
    public var processes: [InferenceProcessInfo] = []
    /// Services found on this machine, offered to the user as a choice (the scan
    /// proposes, the user decides — an idle leftover looks exactly like a live
    /// endpoint to a port scan).
    public var inferenceCandidates: [InferenceCandidate] = []
    /// Which service this card is showing ("auto" / ":8888" / "hidden") — kept
    /// here so both the UI and the debug dump report the same thing.
    public var inferenceSourceLabel: String = "auto"
    /// Why the inference row is missing/blank — surfaced in the UI so a blocked
    /// request is never silently reported as "no model running".
    public var inferenceError: String?
    /// Still working on the very first sample. Distinguishes "nothing yet" from
    /// "answered and failed" — showing 无响应 during startup is a lie.
    public var connecting: Bool
    /// Transient note about the inference channel (e.g. "自动发现 → :11434 Ollama").
    public var inferenceNote: String?
    /// Whether an inference endpoint is configured at all. Without this the UI
    /// cannot tell "no endpoint set" from "endpoint set, probing not finished",
    /// and ends up claiming 未配置 while a probe is still in flight.
    public var inferenceConfigured: Bool
    public var health: HealthReport
    /// The dashboard channel is waiting for a password. Carried as its own flag
    /// rather than inferred from an error string so every surface (menu bar,
    /// card, login button, main window) agrees on what state this node is in.
    public var awaitingCredentials: Bool = false
    public var error: String?
    public var updatedAt: Date
    /// Whole-machine power, from the single shared model (see `PowerEstimate`).
    /// Computed where the CPU side and the topology are known, so every surface
    /// prints the same number and the same confidence.
    public var power: PowerEstimate.Reading?
    /// Which documented failure signature this box currently matches, if any.
    public var faultMode: FaultMode?
    /// Whether a fixed clock appears to be in effect, and at what frequency.
    public var clockLock: ClockLockState?
    /// How fast the hottest ACPI zone is climbing, when there is enough data.
    public var thermalTrend: ThermalTrend.Reading?
    /// How the box stopped last time (clean shutdown vs suspected power cut).
    public var forensics: BootForensics?
    /// True when this node is a member of a multi-node (tensor-parallel) task.
    /// The wall draw of a Spark in a collective is not the same function of its
    /// GPU rail as a solo box's — the peer link keeps burning while a rank waits.
    public var collective: Bool = false
    /// Age of the newest sample from the 2 s thermal stream. Nil when the stream
    /// never delivered one; grows while the stream is dead, which is the only
    /// honest way to distinguish "steady temperature" from "no data".
    public var fastSampleAge: TimeInterval?
    /// Per-section line counts from the last slow SSH probe. Diagnostic only: it
    /// answers "did the probe not see that section, or does the box not have it".
    public var slowProbeSections: [String: Int] = [:]

    public init(
        id: UUID,
        name: String,
        host: String,
        source: DataSource = .down,
        gpu: GpuSample = GpuSample(),
        system: SystemSample = SystemSample(),
        inference: InferenceSample? = nil,
        processes: [InferenceProcessInfo] = [],
        inferenceCandidates: [InferenceCandidate] = [],
        inferenceSourceLabel: String = "auto",
        inferenceError: String? = nil,
        inferenceNote: String? = nil,
        connecting: Bool = false,
        inferenceConfigured: Bool = false,
        health: HealthReport = HealthReport(level: .unknown, reasons: []),
        awaitingCredentials: Bool = false,
        error: String? = nil,
        updatedAt: Date = Date(),
        power: PowerEstimate.Reading? = nil,
        faultMode: FaultMode? = nil,
        clockLock: ClockLockState? = nil,
        thermalTrend: ThermalTrend.Reading? = nil,
        forensics: BootForensics? = nil,
        collective: Bool = false,
        fastSampleAge: TimeInterval? = nil,
        slowProbeSections: [String: Int] = [:]
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.source = source
        self.gpu = gpu
        self.system = system
        self.inference = inference
        self.processes = processes
        self.inferenceCandidates = inferenceCandidates
        self.inferenceSourceLabel = inferenceSourceLabel
        self.inferenceError = inferenceError
        self.inferenceNote = inferenceNote
        self.connecting = connecting
        self.inferenceConfigured = inferenceConfigured
        self.health = health
        self.awaitingCredentials = awaitingCredentials
        self.error = error
        self.updatedAt = updatedAt
        self.power = power
        self.faultMode = faultMode
        self.clockLock = clockLock
        self.thermalTrend = thermalTrend
        self.forensics = forensics
        self.collective = collective
        self.fastSampleAge = fastSampleAge
        self.slowProbeSections = slowProbeSections
    }
}

