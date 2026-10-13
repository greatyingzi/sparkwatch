import AppKit
import Foundation
import SparkWatchCore

/// UI-facing state: snapshots plus the short history the sparklines need.
///
/// The collector is an actor and publishes on its own cadence; this model is the
/// single MainActor bridge so SwiftUI never touches actor state directly.
@MainActor
final class AppModel: ObservableObject {
    /// One minute of 1 Hz samples is plenty for a glance-level trend.
    private static let historyLength = 60

    struct History {
        var util: [Double] = []
        var memPct: [Double] = []
        var tps: [Double] = []
    }

    @Published private(set) var nodes: [NodeSnapshot] = []
    @Published private(set) var history: [UUID: History] = [:]
    @Published var lastUpdate = Date()
    @Published var statusBarText = "DGX …"
    /// Coloured version of the same string, for the status item.
    @Published var statusBarAttributed = NSAttributedString(string: "DGX …")
    @Published private(set) var isPaused = false
    private var statusBarSettings = StatusBarSettings()
    /// node -> chosen inference source, mirrored from settings for the pickers.
    private var settingsSource: [UUID: InferenceSource] = [:]
    @Published private(set) var powerEstimate = PowerEstimate()
    /// Power display smoothing window in seconds (0 = raw). Mirrored for the
    /// tooltips, which explain what the shown number is a mean of.
    @Published private(set) var powerWindowSeconds: Double = 8
    /// Deployments spanning several machines. Rebuilt from the process tables on
    /// the slow channel, so this is a topology view, not a per-node guess.
    @Published private(set) var tasks: [ClusterTask] = []
    private var lastTaskRefresh = Date.distantPast
    /// Which palette to paint with. Mirrored from settings so the views can
    /// resolve tokens without re-reading the config file.
    @Published private(set) var theme: AppTheme = .system
    /// Hardware stream cadence, shown in the popover header. Kept here so the
    /// header states the real number instead of a hard-coded one.
    @Published private(set) var pollSeconds: Double = 2

    // MARK: - Time series
    //
    // The ledgers own the arithmetic; these are the mirrors SwiftUI reads. They
    // are refreshed once per tick rather than on demand, so a chart and a footer
    // can never disagree about the same instant.
    /// Preview and command-line instances may read the ledgers but must **not** write
    /// them. A render run used to load the shared file, add the couple of seconds it
    /// had collected and save that back — which is how the real machine's persisted
    /// history ended up looking threadbare.
    let ledgers: LedgerStore
    @Published private(set) var energySnapshot: EnergyLedger.Snapshot?
    @Published private(set) var hourlyWatts: [Double?] = []
    @Published private(set) var tokenTotals = TokenLedger.Totals(prompt: 0, completion: 0, cached: 0)
    @Published private(set) var tokenRows: [TokenLedger.ModelRow] = []
    /// Per-day completion tokens (UTC days), oldest first, for the token page's
    /// chart. Days with no data come back as 0 from the ledger; the page draws those
    /// as stubs so "no traffic" is not confused with "no measurement".
    @Published private(set) var tokenDaily: [(day: String, completion: Double)] = []
    @Published private(set) var events: [WatchEvent] = []
    /// Which window the token pages show. The ledger keeps 35 days, so this is a
    /// view choice rather than a data limit.
    @Published var tokenRange: TokenLedger.Range = .today
    /// The stored machine configs. Kept here so a page that needs an SSH user
    /// (benchmarks reaching a loopback-bound engine, shutting a machine down) does
    /// not have to re-read the settings file.
    @Published private(set) var nodeConfigs: [NodeConfig] = []

    let collector: ClusterCollector

    /// `readOnlyLedgers: true` keeps a preview/CLI run from writing the ledgers on disk
    /// (it still reads them) — see the note on `ledgers`.
    init(collector: ClusterCollector, readOnlyLedgers: Bool = false) {
        self.collector = collector
        self.ledgers = LedgerStore(readOnly: readOnlyLedgers)
    }

    func start() async {
        let current = await collector.currentSettings()
        statusBarSettings = current.statusBar
        powerEstimate = current.powerEstimate
        powerWindowSeconds = current.powerWindowSeconds
        theme = current.appearance
        pollSeconds = current.sampleIntervalSeconds
        nodeConfigs = current.nodes
        settingsSource = Dictionary(
            uniqueKeysWithValues: current.nodes.map { ($0.id, $0.inferenceSource) }
        )
        await collector.start()
        tasks = await collector.refreshClusterTasks()
        lastTaskRefresh = Date()
        await refresh()
    }

    func setPaused(_ paused: Bool) async {
        guard paused != isPaused else { return }
        await togglePause()
    }

    func togglePause() async {
        if isPaused {
            await collector.resume()
            isPaused = false
        } else {
            await collector.pause()
            isPaused = true
        }
        await refresh()
    }

    /// Debug/preview only: render a fleet we do not own. Set by --demo-devices.
    private var demoNodes: [NodeSnapshot]?

    func useDemoData(nodeCount: Int) {
        demoNodes = DemoData.snapshots(count: nodeCount)
        nodes = demoNodes ?? []
        tasks = DemoData.tasks(for: nodes)
        lastUpdate = Date()
        seedHistory()
    }

    /// CLI/preview only: force a palette without touching stored settings, so
    /// `--preview --theme oled` renders what the user would actually get.
    func overrideTheme(_ theme: AppTheme) {
        self.theme = theme
    }

    /// A flat history so sparklines render something meaningful in a still frame.
    private func seedHistory() {
        for node in nodes {
            var entry = History()
            let base = node.gpu.utilPct ?? 0
            entry.util = (0..<40).map { _ in min(100, max(0, base + Double.random(in: -12...12))) }
            entry.memPct = Array(repeating: node.gpu.memUsedPct ?? 0, count: 40)
            let tps = node.inference?.decodeTPS ?? 0
            entry.tps = (0..<40).map { _ in max(0, tps + Double.random(in: -3...3)) }
            history[node.id] = entry
        }
    }

    func refresh() async {
        if demoNodes != nil { return }   // synthetic fleet: nothing to poll
        // Topology changes only when a deployment starts or stops, which the
        // slow channel sees; refreshing it every second would just re-persist
        // the same settings.
        // Refresh on the interval, and immediately while nothing has been
        // detected yet: the first slow probe lands a few seconds after launch
        // and waiting the full interval just delays the task banner for no
        // reason (the topology is derived from cached process tables, so an
        // extra pass is nearly free).
        if tasks.isEmpty || Date().timeIntervalSince(lastTaskRefresh) >= 15 {
            lastTaskRefresh = Date()
            tasks = await collector.refreshClusterTasks()
        }
        let snapshots = await collector.snapshots()
        nodes = snapshots
        lastUpdate = Date()
        // Feed the time series from what the collector already produced — no extra
        // traffic on the boxes.
        ledgers.record(nodes: snapshots, tasks: tasks)
        mirrorLedgers()
        for snapshot in snapshots {
            var entry = history[snapshot.id] ?? History()
            if let util = snapshot.gpu.utilPct { entry.util.append(util) }
            if let pct = snapshot.gpu.memUsedPct { entry.memPct.append(pct) }
            entry.tps.append(snapshot.inference?.decodeTPS ?? 0)
            entry.util = entry.util.suffix(Self.historyLength)
            entry.memPct = entry.memPct.suffix(Self.historyLength)
            entry.tps = entry.tps.suffix(Self.historyLength)
            history[snapshot.id] = entry
        }
        if isPaused {
            statusBarText = "⏸ 已暂停"
            statusBarAttributed = NSAttributedString(
                string: "⏸ 已暂停",
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            )
            return
        }
        statusBarText = Self.summary(
            for: snapshots, settings: statusBarSettings, powerEstimate: powerEstimate
        )
        statusBarAttributed = Self.attributedSummary(
            for: snapshots, settings: statusBarSettings, powerEstimate: powerEstimate
        )
    }

    func login(nodeID: UUID, username: String, password: String) async -> String? {
        let result = await collector.login(nodeID: nodeID, username: username, password: password)
        await refresh()
        if case let .failure(error) = result { return error.message }
        return nil
    }

    /// Set which inference service a machine shows (the scan proposes, the user
    /// decides), persist it, and rebuild that runtime.
    func setInferenceSource(nodeID: UUID, source: InferenceSource) async {
        var settings = await collector.currentSettings()
        guard let index = settings.nodes.firstIndex(where: { $0.id == nodeID }),
            settings.nodes[index].inferenceSource != source
        else { return }
        settings.nodes[index].inferenceSource = source
        settingsSource[nodeID] = source
        await apply(settings: settings)
    }

    /// The stored source choice for a machine (the picker's current value).
    func inferenceSource(for nodeID: UUID) -> InferenceSource {
        nodes.first { $0.id == nodeID }.map { _ in
            settingsSource[nodeID] ?? .auto
        } ?? .auto
    }

    func signedInUsername(nodeID: UUID) -> String? {
        SessionStore.username(for: nodeID)
    }

    /// Apply an edited configuration: rebuild the runtimes and drop history for
    /// nodes that no longer exist (otherwise a re-added node inherits the old
    /// sparkline).
    func apply(settings: AppSettings) async {
        let previousIDs = Set(nodes.map(\.id))
        statusBarSettings = settings.statusBar
        powerEstimate = settings.powerEstimate
        powerWindowSeconds = settings.powerWindowSeconds
        theme = settings.appearance
        pollSeconds = settings.sampleIntervalSeconds
        nodeConfigs = settings.nodes
        await collector.apply(settings: settings)
        tasks = await collector.refreshClusterTasks()
        lastTaskRefresh = Date()
        await refresh()
        let currentIDs = Set(nodes.map(\.id))
        for stale in previousIDs.subtracting(currentIDs) {
            history.removeValue(forKey: stale)
        }
    }

    func signOut(nodeID: UUID) async {
        await collector.signOut(nodeID: nodeID)
        await refresh()
    }

    // MARK: - Ledger access

    private func mirrorLedgers() {
        let now = Date()
        energySnapshot = ledgers.energy.snapshot(now: now)
        hourlyWatts = ledgers.energy.hourlyWatts(hours: 24, now: now)
        tokenTotals = ledgers.tokens.totals(tokenRange, now: now)
        tokenRows = ledgers.tokens.byModel(tokenRange, now: now)
        tokenDaily = ledgers.tokens.dailyCompletion(days: 14, now: now)
        events = ledgers.events.recent(limit: 80)
    }

    func setTokenRange(_ range: TokenLedger.Range) {
        tokenRange = range
        mirrorLedgers()
    }

    /// Recent GPU samples for one machine, for the history chart.
    func historyPoints(for nodeID: UUID, window: TimeInterval) -> [GpuHistory.Point] {
        ledgers.history.points(nodeID: nodeID, window: window, now: Date())
    }

    /// The same series resampled into a fixed number of buckets (nil = no data in
    /// that bucket, which is how a gap in coverage stays visible instead of being
    /// drawn as a straight line). `utilLow`/`utilHigh` are the per-bucket extremes —
    /// the chart draws them as an envelope, because on this hardware utilisation
    /// swings 95 % ↔ 0 % within a single bucket.
    func binnedHistory(for nodeID: UUID, window: TimeInterval, buckets: Int = 200)
        -> (util: [Double?], power: [Double?], temp: [Double?],
            utilLow: [Double?], utilHigh: [Double?],
            maxUtil: Double?, maxPower: Double?, maxTemp: Double?)
    {
        GpuHistory.binned(
            historyPoints(for: nodeID, window: window),
            into: buckets, window: window, now: Date()
        )
    }

    /// How much history actually exists for this machine, in seconds (capped at the
    /// ring's own 8 h). The chart uses it to zoom the x-axis to the data instead of
    /// drawing a mostly-empty canvas for the first half hour after a launch.
    func historySpan(for nodeID: UUID) -> TimeInterval {
        let points = ledgers.history.points(nodeID: nodeID, window: 8 * 3600, now: Date())
        guard let oldest = points.first?.at, let newest = points.last?.at else { return 0 }
        return max(0, newest.timeIntervalSince(oldest))
    }

    /// Change the palette from anywhere (palette command, settings window).
    func setTheme(_ theme: AppTheme) async {
        var settings = await collector.currentSettings()
        guard settings.appearance != theme else { return }
        settings.appearance = theme
        await apply(settings: settings)
    }

    func noteAction(_ message: String, severity: WatchEvent.Severity = .info, kind: String, node: NodeSnapshot? = nil) {
        ledgers.note(message, severity: severity, kind: kind, node: node)
        mirrorLedgers()
    }

    func saveLedgers() {
        ledgers.save(force: true)
    }

    /// The one-line glance. Every element is decided in `StatusBarText` (pure,
    /// unit-tested); this layer only injects the settings and colours the result.
    static func summary(
        for snapshots: [NodeSnapshot],
        settings: StatusBarSettings,
        powerEstimate: PowerEstimate = PowerEstimate()
    ) -> String {
        StatusBarText.text(for: snapshots, settings: settings, powerEstimate: powerEstimate)
    }

    static func segments(
        for snapshots: [NodeSnapshot],
        settings: StatusBarSettings,
        powerEstimate: PowerEstimate = PowerEstimate()
    ) -> [StatusSegment] {
        StatusBarText.segments(for: snapshots, settings: settings, powerEstimate: powerEstimate)
    }

    static func color(for tone: StatusTone) -> NSColor {
        switch tone {
        case .normal: .labelColor
        case .good: .systemGreen
        case .degraded: .systemOrange
        case .warning: .systemYellow
        case .critical: .systemRed
        }
    }

    /// Same content, with each segment coloured by its tone.
    static func attributedSummary(
        for snapshots: [NodeSnapshot],
        settings: StatusBarSettings,
        powerEstimate: PowerEstimate = PowerEstimate()
    ) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let result = NSMutableAttributedString()
        let segments = StatusBarText.segments(
            for: snapshots, settings: settings, powerEstimate: powerEstimate
        )
        for (index, segment) in segments.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(
                    string: " ",
                    attributes: [.font: font, .foregroundColor: NSColor.labelColor]
                ))
            }
            result.append(NSAttributedString(
                string: segment.text,
                attributes: [.font: font, .foregroundColor: Self.color(for: segment.tone)]
            ))
        }
        return result
    }
}
