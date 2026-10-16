import Foundation

/// Per-node supervisor: owns the tunnel, the token, the SSE stream, the slow
/// SSH probe and the inference scrape, and publishes one `NodeSnapshot`.
///
/// Design notes
///  * Nothing is installed on the boxes. The dashboard channel is reached
///    through our own SSH forward; the inference channel is read straight off
///    the tailnet; the slow channel is plain `ssh`.
///  * Degradation is explicit: if the dashboard channel is unavailable the node
///    flips to `.sshFallback` (hardware from `nvidia-smi` + `/proc/meminfo`, no
///    model/throughput rows) instead of going dark.
///  * The token is an actor-local cache; the 0600 sessions file is the durable copy.
public actor NodeRuntime {
    /// Mutable so a discovered endpoint can be adopted at runtime.
    private var config: NodeConfig
    /// Called when an endpoint is auto-discovered, so it can be persisted.
    public var onEndpointAdopted: (@Sendable (UUID, String) async -> Void)?
    private var discoveryRunning = false
    private var lastDiscovery = Date.distantPast
    private var consecutiveInferenceFailures = 0
    private var discoveryNote: String?
    private let dashboard: DashboardClient
    private let tunnel: SshTunnel
    private let inferenceProbe = InferenceProbe()
    private var rateTracker = TokenRateTracker()
    /// Engine-accounted decode rate (Δtokens ÷ Δdecode-seconds) — the preferred
    /// source whenever the engine exposes its own decode clock.
    private var engineRateTracker = EngineDecodeRateTracker()
    /// Prefill speed comes from the engine's own accounting (computed prompt
    /// tokens per prefill second), not from a wall-clock delta — see
    /// `PrefillRateTracker`.
    private var prefillTracker = PrefillRateTracker()
    private var healthEvaluator = HealthEvaluator()

    private var gpu = GpuSample()
    private var system = SystemSample()
    private var inference: InferenceSample?
    private var inferenceError: String?
    /// What this node is running, from the slow channel's process table.
    private var processes: [InferenceProcessInfo] = []
    /// Set when this node is a headless rank of a distributed task: it owns no
    /// HTTP endpoint, so probing a URL can only ever return a stranger's answer
    /// (typically a stale, idle engine on loopback). The cluster layer fills the
    /// inference row with the task's real model instead.
    private var suppressInferenceProbe = false
    /// This node's role in its deployment ("rank 0 · API"). Kept out of the
    /// probe result so a probe refresh cannot wipe it.
    private var taskRole: String?
    /// Set when a probe's reading was rejected as diluted: probe again almost
    /// immediately to establish a clean baseline.
    private var forceProbeAt: Date?
    /// When the box was first seen working (GPU busy or the engine reporting
    /// in-flight work). Used to reject a rate whose interval straddles the start.
    private var workStartedAt: Date?
    /// Services seen on this machine, for the picker.
    private var candidates: [InferenceCandidate] = []
    /// SM clock from the slow channel. Held outside `gpu` on purpose: the
    /// dashboard stream replaces the whole GPU sample once a second and would
    /// wipe a field only the SSH channel can fill (which it did — the wedge rule
    /// silently never saw a clock).
    private var smClockMHz: Double?
    /// Trailing mean of the power samples. Fed wherever a power reading arrives
    /// (dashboard ~1 Hz, SSH as a fallback) and read back at snapshot time.
    private var powerSmoother = TimeWindowMean(windowSeconds: 8)
    /// Liveness of the two hardware channels; `source` is derived from them so a
    /// slow-loop success can never mask a healthy dashboard feed (or vice versa).
    private var dashboardLive = false
    private var sshLive = false
    private var error: String?
    private var updatedAt = Date()
    private var token: String?
    private var tokenExpiry: Date?
    private var needsCredentials = false
    private var started = false
    private var slowProbeInterval: TimeInterval = 60
    /// Previous kernel-error counters, for rise detection. `nil` until the first
    /// probe that could actually read the log.
    private var lastKernelErrors: KernelErrors?
    /// When a counter last rose. The finding stays visible for `incidentDwell`
    /// rather than for a single probe interval: a one-off Xid at 03:00 must still
    /// be on screen at 09:00.
    private var lastIncidentAt: Date?
    static let incidentDwell: TimeInterval = 3600
    private var sampleInterval: TimeInterval = 2
    private var lastSlowProbe = Date.distantPast
    private var lastInference = Date.distantPast
    /// When the inference probe last answered. `snapshot()` derives the rate's age
    /// from this, so a probe that stops answering cannot keep presenting its last
    /// number as if it were live.
    private var lastInferenceSuccess = Date.distantPast
    /// An endpoint we could not reach directly, and when we last checked. See the
    /// comment in the inference loop: retrying a known-blocked direct path every
    /// cycle wastes a timeout and can starve the loop.
    private var directBlockedURL: String?
    private var directBlockedAt = Date.distantPast
    /// Standing forward for the engine's own HTTP port (`-L 127.0.0.1:<local>:localhost:<port>`).
    ///
    /// Probing over a fresh `ssh … curl` paid three or four handshakes per cycle, and
    /// when one of them stalled the whole inference loop starved: the bar kept a stale
    /// `×1` while the engine decoded at 38 tok/s (measured on the real fleet
    /// 2026-10-03, stack parked in `SshRunner.run`). The dashboard has always been read
    /// through a standing tunnel; the engine endpoint gets the same treatment, so a
    /// probe becomes a loopback call.
    private var inferenceTunnel: SshTunnel?
    private var inferenceTunnelRemotePort: Int?
    private let startedAt = Date()
    /// True once any channel has produced a sample; until then a "down" node is
    /// really just "still connecting" and must not be reported as failed.
    private var everLive = false

    public init(config: NodeConfig) {
        self.config = config
        self.dashboard = DashboardClient(
            baseURL: URL(string: "http://127.0.0.1:\(config.dashboardLocalPort)")!
        )
        self.tunnel = SshTunnel(
            host: config.sshHost,
            user: config.sshUser,
            localPort: config.dashboardLocalPort
        )
        // A token that is already stale on disk is not "progress": the sign-in wait
        // keys off usable-ness, and a present-but-expired token used to be mistaken
        // for one (see Credentials.swift). Decide it here — `init` is the one place
        // that cannot call into the actor — and drop the stale token before any
        // loop runs, in memory *and* on disk, because `SessionStore` is what the
        // next launch reads.
        let stored = SessionStore.token(for: config.id)
        let storedExpiry = stored.flatMap(TelemetryParser.jwtExpiry)
        if CredentialGate.isUsable(token: stored, expiry: storedExpiry) {
            self.token = stored
            self.tokenExpiry = storedExpiry
        } else {
            self.token = nil
            self.tokenExpiry = nil
            self.needsCredentials = true
            if stored != nil { SessionStore.clear(for: config.id) }
        }
    }

    public var configuration: NodeConfig { config }
    public var awaitingCredentials: Bool { needsCredentials }

    /// What the credential wait reads. One place, so `token`/`tokenExpiry` can
    /// never be compared out of step with each other.
    var credentialState: CredentialState {
        CredentialState(token: token, expiry: tokenExpiry)
    }

    /// Forget a token that can no longer authenticate — in memory *and* on disk.
    ///
    /// Keeping it would be load-bearing in a bad way: `SessionStore` is what the
    /// next launch reads, so a stale token that survived a quit would put the app
    /// straight back into the wait with nothing to wait for.
    private func discardUnusableToken() {
        guard token != nil else { return }
        guard !CredentialGate.isUsable(credentialState) else { return }
        token = nil
        tokenExpiry = nil
        needsCredentials = true
        SessionStore.clear(for: config.id)
    }

    /// The dashboard channel is waiting for a password. Only the *transition* is
    /// news: `updatedAt` is a freshness claim ("this data is this new"), and this
    /// wait repeats once a second carrying no data, so re-marking it every pass
    /// would keep stale numbers looking freshly measured.
    private func noteCredentialWait() {
        needsCredentials = true
        guard dashboardLive || error != CredentialGate.needsLoginReason else { return }
        markDashboardDown(reason: CredentialGate.needsLoginReason, refreshingFreshness: false)
    }

    public func setAdoptionHandler(_ handler: @escaping @Sendable (UUID, String) async -> Void) {
        onEndpointAdopted = handler
    }

    public func configure(
        sampleInterval: TimeInterval,
        slowProbeInterval: TimeInterval,
        powerWindowSeconds: Double = 8
    ) {
        setPowerWindow(powerWindowSeconds)

        self.sampleInterval = sampleInterval
        self.slowProbeInterval = slowProbeInterval
    }

    public func start() {
        guard !started else { return }
        started = true
        Task { await hardwareLoop() }
        Task { await slowLoop() }
        Task { await inferenceLoop() }
        if config.inferenceSource == .hidden {
            // The user said "not interesting": stop probing, and stop the
            // scanner from adopting something on its own.
            suppressInferenceProbe = true
            inference = nil
            inferenceError = nil
            return
        }
        if let pinned = config.inferenceSource.pinnedURL, !pinned.isEmpty {
            // A pin is an instruction, not a hint: probe exactly this, and if it
            // fails say so instead of drifting to another service's numbers.
            if config.inferenceMetricsURL != pinned {
                config.inferenceMetricsURL = pinned
                discoveryNote = "已固定 \(pinned)"
                consecutiveInferenceFailures = 0
                rateTracker = TokenRateTracker()
                engineRateTracker = EngineDecodeRateTracker()
                inferenceError = nil
            }
            return
        }
        if config.autoDiscover, config.inferenceMetricsURL?.isEmpty != false {
            Task { await discoverEndpoint(reason: "未配置端点，自动发现") }
        }
    }

    /// Ask the box itself what is listening, and adopt the most convincing
    /// inference endpoint. Runs over SSH, so it works for loopback-only engines.
    private func discoverEndpoint(reason: String) async {
        guard !discoveryRunning, started else { return }
        discoveryRunning = true
        lastDiscovery = Date()
        defer { discoveryRunning = false }

        let hits = await Diagnostics.discoverInferenceEndpoints(
            user: config.sshUser, host: config.sshHost
        )
        // Only adopt something unambiguous: an engine-specific metrics endpoint
        // (30), an engine-native model API (25) or generic Prometheus (20). A bare
        // OpenAI model list can be any web service, so it is only adopted when it
        // is the single candidate.
        guard let chosen = Diagnostics.chooseEndpoint(from: hits) else { return }
        let port = chosen.port

        let url = chosen.url(forHost: config.sshHost)
        await setInferenceEndpoint(url, note: "\(reason) → 自动选中 :\(port) \(chosen.engine ?? "")\(chosen.model.map { " · \($0)" } ?? "")")
        _ = port
    }

    /// Point this node's inference probe at an endpoint. Used both by port
    /// discovery and by the cluster layer, which knows the port from the
    /// process's own `--port` flag — a far better source than a scan.
    public func setInferenceEndpoint(_ url: String, note: String? = nil) async {
        if url == config.inferenceMetricsURL { return }
        config.inferenceMetricsURL = url
        if let note { discoveryNote = note }
        consecutiveInferenceFailures = 0
        rateTracker = TokenRateTracker()
                engineRateTracker = EngineDecodeRateTracker()
        prefillTracker = PrefillRateTracker()
        inferenceError = nil
        await onEndpointAdopted?(config.id, url)
    }

    public func stop() {
        started = false
        inferenceTunnel?.stop()
        inferenceTunnel = nil
        tunnel.stop()
    }

    private var source: DataSource {
        if dashboardLive { return .dashboard }
        if sshLive { return .sshFallback }
        return .down
    }

    /// What the user asked this machine's inference row to show.
    public var inferenceSource: InferenceSource { config.inferenceSource }

    /// Called by the cluster layer once the deployment topology is known.
    ///
    /// Suppression means "this box has no endpoint of its own", so everything the
    /// URL probe concluded has to go with it. The note in particular is written on
    /// a different schedule than the topology: the auto-discovery pass runs at
    /// startup, finds a leftover engine on loopback (an idle Ollama with an old
    /// model loaded), and records "自动选中 :11434 Ollama · qwen2.5:0.5b" — which
    /// then sat under a headless rank's task model, naming a service the box has
    /// nothing to do with.
    public func setSuppressInferenceProbe(_ suppress: Bool) {
        suppressInferenceProbe = suppress
        if suppress {
            inferenceError = nil
            discoveryNote = nil
        }
    }

    /// Feed a power reading into the smoother and return a sample whose `powerW`
    /// is the windowed mean (with the raw kept in `powerInstantW`). Every
    /// consumer — cards, the whole-machine estimate, the wedge rule — then reads
    /// the stable figure by default, and the raw one stays available.
    private func absorbed(_ sample: GpuSample) -> GpuSample {
        var out = sample
        // The dashboard stream replaces the whole GPU sample once a second, and
        // it carries no clocks, no power limit and no throttle reasons — those
        // only ever come from the SSH probe. Dropping them here is what made the
        // low-power-wedge rule silently never see a clock at all (measured on
        // this fleet): the rule was in place, the data was being wiped each tick.
        out.smClockMHz = out.smClockMHz ?? self.gpu.smClockMHz
        out.powerLimitW = out.powerLimitW ?? self.gpu.powerLimitW
        out.throttle = out.throttle ?? self.gpu.throttle
        guard let instant = sample.powerW else { return out }
        out.powerInstantW = instant
        powerSmoother.add(instant, at: Date().timeIntervalSince1970)
        if let mean = powerSmoother.mean { out.powerW = mean }
        return out
    }

    /// Apply a settings change to the smoothing window (0 disables it).
    public func setPowerWindow(_ seconds: Double) {
        guard seconds != powerSmoother.windowSeconds else { return }
        powerSmoother = TimeWindowMean(windowSeconds: seconds)
        if let instant = gpu.powerInstantW ?? gpu.powerW {
            powerSmoother.add(instant, at: Date().timeIntervalSince1970)
        }
    }

    public func setTaskRole(_ role: String?) { taskRole = role }

    public func currentProcesses() -> [InferenceProcessInfo] { processes }

    public func applyProcesses(_ infos: [InferenceProcessInfo]) { processes = infos }

    /// Adopt the model identity of the task this node belongs to (a headless
    /// worker has no API to ask, but it is running exactly this model).
    ///
    /// Deliberately a *fresh* sample rather than a mutation of the current one:
    /// that one belongs to whatever the URL probe last found, and its engine
    /// label, capabilities, counters and VRAM figure all describe that stranger.
    /// Inheriting them made a rank's card print the leftover engine's profile
    /// ("该引擎不提供速率/请求计数") underneath the task's model.
    public func adoptTaskModel(_ model: String, role: String) {
        var sample = InferenceSample()
        sample.engine = "cluster"
        sample.model = model
        // No in-flight count: this rank serves no HTTP of its own, so it has none
        // to report. It used to say `running = 1` (meaning "this rank is up"),
        // which the menu bar now reads as a request in flight — a permanent `×1`
        // while the deployment sat idle.
        sample.taskRole = role
        inference = sample
        inferenceError = nil
        updatedAt = Date()
    }

    public func snapshot() -> NodeSnapshot {
        let connecting = !everLive && Date().timeIntervalSince(startedAt) < 20
        var inference = self.inference
        if let taskRole { inference?.taskRole = taskRole }
        // Age the rate at *read* time, not at measurement time.
        //
        // The stored age is the age it had when it was written (usually 0), so a
        // probe that stopped answering left the last number looking permanently
        // "live": measured live, the menu bar showed a frozen `▶1/s` for three
        // minutes while the box was doing 40-66 tok/s, and a wedged probe kept a
        // green number on screen for 28 minutes. Deriving the age from the last
        // successful probe makes a stalled channel degrade to grey, then expire —
        // which is what actually happened, told honestly.
        if var sample = inference {
            let sinceProbe = Date().timeIntervalSince(lastInferenceSuccess)
            // How old the whole observation is — every sample, rate or not: the
            // instantaneous counters age with it (see `activityAge`).
            sample.activityAge = sinceProbe
            if sample.decodeTPS != nil {
                sample.decodeTPSAge = max(sample.decodeTPSAge ?? 0, sinceProbe)
            }
            inference = sample
        }
        // Merge the slow-channel-only fields into the GPU sample at snapshot time.
        var gpu = self.gpu
        gpu.smClockMHz = smClockMHz
        return NodeSnapshot(
            id: config.id,
            name: config.name,
            host: config.sshHost,
            source: source,
            gpu: gpu,
            system: system,
            inference: inference,
            processes: processes,
            inferenceCandidates: candidates,
            inferenceSourceLabel: {
                switch config.inferenceSource {
                case .auto: "auto"
                case let .pinned(url): url.split(separator: ":").last.map { ":\($0)" } ?? "pinned"
                case .hidden: "hidden"
                }
            }(),
            inferenceError: suppressInferenceProbe ? nil : inferenceError,
            // Same gate as the error: a note written by the URL probe is about a
            // channel this node is no longer using.
            inferenceNote: suppressInferenceProbe ? nil : discoveryNote,
            connecting: connecting,
            inferenceConfigured: config.inferenceMetricsURL?.isEmpty == false,
            health: connecting
                ? HealthReport(level: .unknown, reasons: [])
                : healthEvaluator.evaluate(
                    gpu: gpu, system: system, source: source, error: error,
                    inference: inference, awaitingCredentials: needsCredentials
                ),
            awaitingCredentials: needsCredentials,
            error: error,
            updatedAt: updatedAt
        )
    }

    /// Interactive sign-in; stores only the resulting token.
    @discardableResult
    public func login(username: String, password: String) async -> Result<Void, DashboardError> {
        ensureTunnel()
        // The forward needs a moment before 127.0.0.1:<port> accepts: posting too
        // early yields a connection error that looks exactly like bad credentials.
        var ready = false
        for _ in 0..<20 {
            if await dashboard.isDashboard() { ready = true; break }
            try? await Task.sleep(for: .milliseconds(400))
        }
        guard ready else {
            let failure = DashboardError.transport(
                "SSH 隧道未就绪（\(config.sshHost) → 127.0.0.1:\(config.dashboardLocalPort)）"
            )
            error = failure.message
            return .failure(failure)
        }
        do {
            let token = try await dashboard.login(username: username, password: password)
            self.token = token
            self.tokenExpiry = TelemetryParser.jwtExpiry(token)
            SessionStore.save(token: token, for: config.id)
            SessionStore.setUsername(username, for: config.id)
            needsCredentials = false
            error = nil
            return .success(())
        } catch let dashboardError as DashboardError {
            error = dashboardError.message
            return .failure(dashboardError)
        } catch {
            let wrapped = DashboardError.transport(String(describing: error))
            self.error = wrapped.message
            return .failure(wrapped)
        }
    }

    public func signOut() {
        token = nil
        tokenExpiry = nil
        needsCredentials = true
        SessionStore.clear(for: config.id)
    }

    // MARK: - Loops

    private func ensureTunnel() {
        guard !tunnel.isRunning else { return }
        // A failure here is tolerated rather than reported from this call site:
        // `start()` already retires a spawn that never bound, and the loop's own
        // readiness check (`isDashboard`) is what turns "no tunnel" into a reason
        // the user sees. Logging it per pass would be noise for a state the UI
        // already names.
        try? tunnel.start()
    }

    /// A loopback URL for the engine endpoint, forwarded over the SSH channel we
    /// already own. Returns the original URL unchanged when it is already loopback or
    /// has no port — in that case there is nothing to forward.
    ///
    /// The local port is derived from the dashboard port (one per node, already
    /// unique) so two boxes never fight over the same forward.
    private func loopbackEndpoint(for url: String) -> String {
        guard let parsed = URL(string: url), let port = parsed.port,
            let host = parsed.host, host != "127.0.0.1", host != "localhost"
        else { return url }
        if inferenceTunnelRemotePort == port, let tunnel = inferenceTunnel, tunnel.isRunning {
            return "http://127.0.0.1:\(tunnel.localPort)"
        }
        inferenceTunnel?.stop()
        let localPort = config.dashboardLocalPort + 100
        let tunnel = SshTunnel(
            host: config.sshHost, user: config.sshUser, remotePort: port, localPort: localPort
        )
        do {
            try tunnel.start()
        } catch {
            inferenceTunnel = nil
            inferenceTunnelRemotePort = nil
            return url
        }
        inferenceTunnel = tunnel
        inferenceTunnelRemotePort = port
        return "http://127.0.0.1:\(localPort)"
    }

    private func hardwareLoop() async {
        var attempt = 0
        while started {
            ensureTunnel()
            // Load-bearing: a token that expired while the app kept running must
            // stop looking like a credential before the guard reads it.
            discardUnusableToken()
            if token == nil {
                // Wait for a sign-in. `CredentialWait` asks exactly the question
                // the guard above asks, and sleeps on every pass — the previous
                // inline version exited on "token != nil", which an *expired*
                // token satisfied, so it spun a core per node instead of waiting
                // (see Credentials.swift).
                noteCredentialWait()
                let signedIn = await CredentialWait.until(
                    reading: { [self] in await credentialState },
                    running: { [self] in await started },
                    sleep: { try? await Task.sleep(for: .seconds($0)) }
                )
                guard started else { return }
                guard signedIn != nil else { continue }
            }
            guard let storedToken = token, CredentialGate.isUsable(credentialState) else {
                continue
            }
            needsCredentials = false

            // Tell "our tunnel is up" apart from "something else grabbed the port".
            var ready = false
            for _ in 0..<8 {
                if await dashboard.isDashboard() { ready = true; break }
                try? await Task.sleep(for: .milliseconds(500))
            }
            guard ready else {
                attempt += 1
                markDashboardDown(reason: "隧道/面板未就绪 (\(config.dashboardLocalPort))")
                tunnel.stop()
                try? await Task.sleep(for: ReconnectBackoff.delay(forAttempt: attempt))
                continue
            }

            var sawSample = false
            for await event in dashboard.telemetry(token: storedToken) {
                guard started else { return }
                switch event {
                case .connected:
                    attempt = 0
                case let .sample(sample):
                    sawSample = true
                    gpu = absorbed(sample)
                    dashboardLive = true
                    everLive = true
                    error = nil
                    updatedAt = Date()
                case let .failure(failure):
                    error = failure.message
                    if case .unauthorized = failure {
                        token = nil
                        tokenExpiry = nil
                        needsCredentials = true
                        SessionStore.clear(for: config.id)
                    }
                }
            }

            if !sawSample { markDashboardDown(reason: error ?? "遥测流无数据") }
            attempt += 1
            try? await Task.sleep(for: ReconnectBackoff.delay(forAttempt: attempt))
        }
    }

    private func slowLoop() async {
        var attempt = 0
        while started {
            if Date().timeIntervalSince(lastSlowProbe) >= slowProbeInterval {
                lastSlowProbe = Date()
                do {
                    let result = try await SshProbe.collect(user: config.sshUser, host: config.sshHost)
                    system = result.system
                    // A kernel counter that *rose* is the event; the absolute
                    // value is only a baseline (see KernelErrors). Kept for an
                    // hour so the finding cannot be missed by a single glance
                    // between two probes.
                    if let previous = lastKernelErrors {
                        let rose = result.system.kernelErrors.available
                            && previous.available
                            && (result.system.kernelErrors.xid > previous.xid
                                || result.system.kernelErrors.oomKills > previous.oomKills
                                || result.system.kernelErrors.nvErrNoMemory > previous.nvErrNoMemory)
                        if rose { lastIncidentAt = Date() }
                    }
                    if result.system.kernelErrors.available {
                        lastKernelErrors = result.system.kernelErrors
                    }
                    system.incidentActive = lastIncidentAt
                        .map { Date().timeIntervalSince($0) < Self.incidentDwell } ?? false
                    processes = result.processes
                    candidates = InferenceCandidates.build(
                        listeners: result.listeners,
                        processes: result.processes
                    )
                    sshLive = true
                    everLive = true
                    // Fill the GPU from SSH only while the dashboard channel is
                    // down: nvidia-smi for util/temp/power, meminfo for the
                    // unified pool (never nvidia-smi memory on GB10).
                    // Always: the dashboard stream carries no clocks, and the
                    // wedge rule needs them even while the dashboard is live.
                    if let clock = result.smClockMHz { smClockMHz = clock }
                    // The throttle reasons and the power limit are SSH-only: the
                    // dashboard stream carries neither, so they are copied here
                    // and preserved across dashboard ticks (see `absorbed`).
                    if let throttle = result.gpu.throttle {
                        gpu.throttle = ThrottleInfo(
                            thermal: throttle.thermal,
                            hardware: throttle.hardware,
                            powerCap: throttle.powerCap,
                            smClockMHz: result.smClockMHz ?? throttle.smClockMHz,
                            smClockMaxMHz: throttle.smClockMaxMHz
                        )
                    }
                    if let limit = result.gpu.powerLimitW { gpu.powerLimitW = limit }
                    if !dashboardLive {
                        gpu.utilPct = result.gpu.utilPct ?? gpu.utilPct
                        gpu.tempC = result.gpu.tempC ?? gpu.tempC
                        if let instant = result.gpu.powerW {
                            powerSmoother.add(instant, at: Date().timeIntervalSince1970)
                            gpu.powerInstantW = instant
                            gpu.powerW = powerSmoother.mean ?? instant
                        }
                        gpu.memTotalBytes = result.system.memTotalBytes
                        gpu.memUsedBytes = result.system.memTotalBytes.flatMap { total in
                            result.system.memAvailableBytes.map { total - $0 }
                        }
                        updatedAt = Date()
                    }
                    attempt = 0
                } catch {
                    attempt += 1
                    sshLive = false
                    if self.error == nil || !dashboardLive {
                        self.error = String(describing: error)
                    }
                }
            }
            try? await Task.sleep(for: .seconds(min(slowProbeInterval, 15)))
        }
    }

    private func inferenceLoop() async {
        while started {
            // Re-read each pass: the endpoint may have been auto-discovered or
            // swapped while this loop was running.
            guard !suppressInferenceProbe else {
                try? await Task.sleep(for: .seconds(3))
                continue
            }
            guard let url = config.inferenceMetricsURL, !url.isEmpty else {
                try? await Task.sleep(for: .seconds(3))
                continue
            }
            // Cadence follows the cheap 1 Hz GPU signal, so the first rate after
            // a request starts lands in ~2 s instead of up to 5 s — while an idle
            // deployment is still polled every 6 s.
            let busy = (inference?.running ?? 0) > 0
                || (inference?.decoding ?? 0) > 0
                || (inference?.prefilling ?? 0) > 0
            let cadence = InferenceCadence.interval(
                gpuUtil: gpu.utilPct,
                powerW: gpu.powerW,
                engineBusy: busy
            )
            let working = busy
                || (gpu.utilPct ?? 0) >= InferenceCadence.busyUtilisationPct
                || (gpu.powerW ?? 0) >= InferenceCadence.busyPowerW
            if working {
                if workStartedAt == nil { workStartedAt = Date() }
            } else if Date().timeIntervalSince(lastInference) > 30 {
                workStartedAt = nil          // long idle: next start is a new one
            }
            // A pending re-baseline probe jumps the queue: after a diluted
            // reading we want a clean baseline in ~0.3 s, not after a full
            // cadence — that is the difference between a number at 1.5 s and one
            // at 5 s.
            let rebaselining = forceProbeAt.map { Date() >= $0 } ?? false
            if rebaselining || Date().timeIntervalSince(lastInference) >= cadence {
                forceProbeAt = nil
                lastInference = Date()
                do {
                    // Direct first; macOS blocks an unsigned app from reaching LAN /
                    // tailnet addresses until the user grants "Local Network", so a
                    // failure here is expected on a fresh install — reach the box's
                    // own loopback through the SSH channel we already own instead.
                    var sample: InferenceSample
                    // macOS blocks an unsigned app from LAN/tailnet addresses, and a
                    // box-local port (`:18000`) can never be reached directly at all —
                    // retrying that every probe burned a timeout per cycle, and when it
                    // hung instead of failing fast the whole inference loop starved: the
                    // bar kept a stale `×1` while the engine decoded (measured on the
                    // real fleet 2026-10-03). Remember the verdict, retry occasionally.
                    let loopback = loopbackEndpoint(for: url)
                    let skipDirect = directBlockedURL == url
                        && Date().timeIntervalSince(directBlockedAt) < 300
                    do {
                        if skipDirect { throw InferenceProbeError.directKnownBlocked }
                        sample = try await inferenceProbe.probe(baseURL: loopback)
                        directBlockedURL = nil
                        inferenceError = nil
                        consecutiveInferenceFailures = 0
                    } catch {
                        let direct = String(describing: error)
                        // Same probe, different transport: curl on the box itself.
                        let viaSsh = InferenceProbe(
                            transport: SshCurlTransport(user: config.sshUser, host: config.sshHost)
                        )
                        sample = try await viaSsh.probe(baseURL: url)
                        // Only the *raw remote URL* is worth remembering as blocked: if
                        // the standing forward failed, retrying it next cycle is right.
                        if !skipDirect, loopback == url {
                            directBlockedURL = url
                            directBlockedAt = Date()
                        }
                        // The endpoint answered — through the box's own loopback.
                        // That is a transport fact, not an error: parking it in
                        // `inferenceError` made a working deployment read as
                        // "端点无响应" in every dump and every screenshot.
                        sample.transportNote = "经 SSH 读取（直连不可达：\(direct.prefix(60))）"
                        inferenceError = nil
                    }
                    // Derive the rate from the counter delta here, where the
                    // tracker lives (actor-isolated, so it cannot go inout into
                    // the async probe call). Each cycle builds a *fresh* sample,
                    // so a counter that did not grow simply leaves the rate nil.
                    // Capture the interval *before* updating the trackers: their
                    // update() refreshes the "last probe" timestamp, so measuring
                    // the gap afterwards always reads ~0 and the guard below never
                    // fired (the same trap as the age bug — a refresher eating the
                    // very information the check needs).
                    let intervalSeconds = rateTracker.lastProbeAt.map {
                        Date().timeIntervalSince($0)
                    }
                    // (The engine's own decode-seconds counter is parsed and
                    // tracked — see `EngineDecodeRateTracker` — but deliberately
                    // not used for the live rate: this engine flushes it in
                    // batches, so a 2 s window can see 4.4 s of "decode time" or
                    // none at all. Measured: it read 17.9 tok/s for work running
                    // at 52. A counter with flush granularity coarser than the
                    // sample window is worse than wall time, not better.)
                    //
                    // A wall-clock delta over an interval that contains idle time
                    // is diluted (measured live: 4.8 tok/s reported for work
                    // running at 52). Only an interval that is all-work counts.
                    var rate: Double?
                    // Counters are only comparable within one engine+model. Swapping
                    // the model on the box (or switching engines) rebases the totals,
                    // and a subtraction across that boundary is not a rate. A model
                    // name that is simply *missing* this cycle must not count as a
                    // swap, or a flaky probe would reset the baseline forever.
                    if let generation = sample.generationTokens,
                        let wall = rateTracker.update(
                            generationTokens: generation,
                            engine: sample.engine,
                            model: sample.model
                        ),
                        SpeedDisplay.rateIsTrustworthy(
                            intervalSeconds: intervalSeconds,
                            activeCadence: InferenceCadence.active
                        )
                    {
                        rate = wall
                    } else if intervalSeconds != nil,
                        SpeedDisplay.rateIsTrustworthy(
                            intervalSeconds: intervalSeconds,
                            activeCadence: InferenceCadence.active
                        ) == false
                    {
                        // The interval straddled idle time, so this reading is
                        // unusable — but the counter has now been re-baselined, so
                        // probe again almost immediately instead of waiting out a
                        // full cadence: that is the difference between a number at
                        // 1.5 s and a number at 5 s.
                        forceProbeAt = Date().addingTimeInterval(0.3)
                    }
                    if let rate {
                        sample.decodeTPS = rate
                        sample.decodeTPSAge = 0
                    } else {
                        // The counter did not move: the deployment may simply have
                        // finished. Keep the last measured rate *with its age* so
                        // the UI can grey it (last known) rather than either lying
                        // green or dropping to a bare dash.
                        sample.decodeTPS = rateTracker.lastRate
                        sample.decodeTPSAge = rateTracker.age()
                    }
                    if let delta = prefillTracker.update(
                        promptTokens: sample.promptTokens,
                        cachedTokens: sample.cachedTokens,
                        prefillSeconds: sample.prefillSeconds,
                        engine: sample.engine,
                        model: sample.model
                    ) {
                        sample.prefillTPS = delta
                    }
                    if ProcessInfo.processInfo.environment["SPARKWATCH_TRACE"] != nil {
                        let gen = sample.generationTokens.map { String(format: "%.0f", $0) } ?? "nil"
                        let tps = sample.decodeTPS.map { String(format: "%.1f", $0) } ?? "nil"
                        let running = sample.running.map { String(format: "%.0f", $0) } ?? "nil"
                        // Captured before the trackers were updated — asking
                        // afterwards always reads ~0 (their update refreshes the
                        // very timestamp the gap is measured from).
                        let since = intervalSeconds.map { String(format: "%.1f", $0) } ?? "nil"
                        let source = engineRateTracker.lastSource
                        // Every link in the chain, so "why is the number late" is
                        // answerable from the log instead of by argument.
                        let line = "[trace] \(config.name) t=\(String(format: "%.2f", Date().timeIntervalSince1970))"
                            + " gap=\(since) gen=\(gen) sec=\(sample.decodeSeconds.map { String(format: "%.1f", $0) } ?? "nil")"
                            + " tps=\(tps) age=\(sample.decodeTPSAge.map { String(format: "%.0f", $0) } ?? "nil") src=\(source) inflight=\(running)"
                            + " cadence=\(String(format: "%.1f", cadence))"
                            // ident = the counters this rate belongs to, and reset=1 when
                            // the tracker threw its baseline away because that identity
                            // changed. Without these two the symptom "engine is busy but
                            // the bar never shows a speed" is indistinguishable from a
                            // stalled probe — measured 2026-10-03, on the real fleet.
                            + " ident=\(sample.engine ?? "-")|\(sample.model ?? "-")"
                            + " reset=\(rateTracker.didResetCounters ? 1 : 0)"
                            + " util=\(gpu.utilPct.map { String(format: "%.0f", $0) } ?? "nil")\n"
                        FileHandle.standardError.write(Data(line.utf8))
                    }
                    inference = sample
                    lastInferenceSuccess = Date()
                } catch {
                    consecutiveInferenceFailures += 1
                    inferenceError = String(describing: error)
                    // Idle endpoint or engine restarting: drop the speed, keep the
                    // last known sample so the UI can grey it out.
                    if var existing = inference {
                        // A failed probe is not proof that work stopped — the
                        // endpoint hiccuped, the box may be mid-request. Keep the
                        // last measurement with its (growing) age so the display
                        // greys it and then expires it, exactly as it does when the
                        // counter simply stops growing. Nilling it here used to
                        // drop the number to "已停止" on a single failed probe.
                        existing.decodeTPS = rateTracker.lastRate
                        existing.decodeTPSAge = rateTracker.age()
                        inference = existing
                    }
                    // A dead endpoint usually means the engine moved ports (a
                    // container restart maps 18300 → 8000, vLLM 8000 → 30000).
                    // Re-discover, at most every 5 minutes, and switch if the box
                    // now answers somewhere else.
                    if config.autoDiscover, consecutiveInferenceFailures >= 6,
                        Date().timeIntervalSince(lastDiscovery) > 300
                    {
                        await discoverEndpoint(reason: "原端点连续 \(consecutiveInferenceFailures) 次无响应")
                    }
                }
            }
            // Short slices so the cadence above is actually honoured: a 2 s
            // cadence behind a 2 s sleep drifts to 4 s, which is the latency the
            // user feels. Cheap — the loop body is one date comparison.
            try? await Task.sleep(for: .milliseconds(400))
        }
    }

    /// The dashboard channel is down.
    ///
    /// `refreshingFreshness` is false for a failure that is *not* a new
    /// observation of the machine (waiting for a password repeats while holding
    /// no data): `updatedAt` is what the UI calls "last update", and pushing it
    /// forward would present stale numbers as freshly measured.
    private func markDashboardDown(reason: String, refreshingFreshness: Bool = true) {
        dashboardLive = false
        error = reason
        if refreshingFreshness { updatedAt = Date() }
    }
}

/// Owns every node runtime and is the single thing the UI talks to.
public actor ClusterCollector {
    private var settings: AppSettings
    private var runtimes: [UUID: NodeRuntime] = [:]
    /// Paused = runtimes stopped but configuration kept, so resuming is instant
    /// and costs nothing but a tunnel re-establish.
    private var paused = false

    public init(settings: AppSettings = SettingsStore.load()) {
        self.settings = settings
    }

    public func apply(settings: AppSettings) async {
        for runtime in runtimes.values { await runtime.stop() }
        runtimes.removeAll()
        self.settings = settings
        try? SettingsStore.save(settings)
        await start()
    }

    public func start() async {
        // Persist the node list on first run so the UUIDs (session-store keys)
        // stay identical across launches and between the app and the probe.
        if !FileManager.default.fileExists(atPath: SettingsStore.settingsURL.path) {
            try? SettingsStore.save(settings)
        }
        for node in settings.nodes where node.enabled {
            let runtime = NodeRuntime(config: node)
            // Discovered endpoints are persisted, so the next launch starts
            // straight from them instead of scanning again.
            await runtime.setAdoptionHandler { [weak self] nodeID, url in
                await self?.persist(endpoint: url, for: nodeID)
            }
            await runtime.configure(
                sampleInterval: settings.sampleIntervalSeconds,
                slowProbeInterval: settings.slowProbeIntervalSeconds,
                powerWindowSeconds: settings.powerWindowSeconds
            )
            await runtime.start()
            runtimes[node.id] = runtime
        }
    }

    public func stop() async {
        for runtime in runtimes.values { await runtime.stop() }
    }

    public func currentSettings() -> AppSettings { settings }

    public var isPaused: Bool { paused }

    public func pause() async {
        paused = true
        for runtime in runtimes.values { await runtime.stop() }
        runtimes.removeAll()
    }

    public func resume() async {
        paused = false
        await start()
    }

    /// Record an auto-discovered endpoint in the config file.
    private func persist(endpoint: String, for nodeID: UUID) {
        guard let index = settings.nodes.firstIndex(where: { $0.id == nodeID }),
            settings.nodes[index].inferenceMetricsURL != endpoint
        else { return }
        settings.nodes[index].inferenceMetricsURL = endpoint
        try? SettingsStore.save(settings)
    }

    /// Groups the enabled nodes into deployments and pushes the resulting roles
    /// back into each runtime: a headless worker stops probing ports and adopts
    /// the task's model, and the API rank gets its endpoint derived from its own
    /// `--port` (not from a URL that may belong to an engine it stopped running
    /// months ago).
    @discardableResult
    public func refreshClusterTasks() async -> [ClusterTask] {
        var members: [(name: String, host: String, processes: [InferenceProcessInfo])] = []
        var byName: [String: UUID] = [:]
        var byID: [UUID: NodeConfig] = [:]
        for node in settings.nodes where node.enabled {
            byName[node.name] = node.id
            byID[node.id] = node
            guard let runtime = runtimes[node.id] else { continue }
            members.append((node.name, node.sshHost, await runtime.currentProcesses()))
        }
        let tasks = ClusterTaskBuilder.build(nodes: members)

        // UI / mock test hook: `SPARKWATCH_ENGINE_OVERRIDE=<url>` points the
        // API-rank probe at a stand-in engine (normally a local mock) so the menu
        // bar can be exercised against scripted data. Everything else — task roles,
        // worker suppression, model adoption — still runs the production path, so
        // what the UI test sees is what production sees. Nothing is persisted, and
        // with the variable unset this code cannot change any behaviour.
        let engineOverride = ProcessInfo.processInfo.environment["SPARKWATCH_ENGINE_OVERRIDE"] ?? ""

        for (taskID, task) in tasks.enumerated() {
            _ = taskID
            for nodeName in task.nodes {
                guard let id = byName[nodeName], let runtime = runtimes[id] else { continue }
                // A pinned or hidden row is an explicit instruction from the
                // person watching: the topology must not overwrite it.
                if await runtime.inferenceSource != .auto && engineOverride.isEmpty { continue }
                let isWorker = nodeName != task.apiNode
                await runtime.setSuppressInferenceProbe(isWorker)
                await runtime.setTaskRole(task.roleLabel(for: nodeName))
                if isWorker {
                    await runtime.adoptTaskModel(task.model, role: task.roleLabel(for: nodeName))
                }
                // The API rank gets the port its own process listens on — a far
                // better source than a URL that may name an engine the box
                // stopped running long ago.
                if !isWorker, let url = task.apiURL {
                    if !engineOverride.isEmpty {
                        await runtime.setInferenceEndpoint(
                            engineOverride, note: "UI 测试：SPARKWATCH_ENGINE_OVERRIDE"
                        )
                        continue
                    }
                    if let index = settings.nodes.firstIndex(where: { $0.id == id }),
                        settings.nodes[index].inferenceMetricsURL != url
                    {
                        settings.nodes[index].inferenceMetricsURL = url
                        try? SettingsStore.save(settings)
                    }
                    await runtime.setInferenceEndpoint(url)
                }
                if isWorker, let index = settings.nodes.firstIndex(where: { $0.id == id }),
                    !(settings.nodes[index].inferenceMetricsURL ?? "").isEmpty
                {
                    // A headless rank answers no HTTP at all; keeping a stale URL
                    // around only invites reading someone else's answer.
                    settings.nodes[index].inferenceMetricsURL = ""
                    try? SettingsStore.save(settings)
                    await runtime.setInferenceEndpoint("")
                }
            }
            // Anyone no longer part of this task goes back to probing normally.
            for node in settings.nodes where node.enabled && !task.nodes.contains(node.name) {
                guard let runtime = runtimes[node.id] else { continue }
                await runtime.setSuppressInferenceProbe(false)
                await runtime.setTaskRole(nil)
            }
        }
        if tasks.isEmpty {
            for (id, runtime) in runtimes where byID[id] != nil {
                await runtime.setSuppressInferenceProbe(false)
                await runtime.setTaskRole(nil)
            }
        }
        return tasks
    }

    public func snapshots() async -> [NodeSnapshot] {
        var out: [NodeSnapshot] = []
        for node in settings.nodes where node.enabled {
            if let runtime = runtimes[node.id] {
                out.append(await runtime.snapshot())
            } else {
                out.append(
                    NodeSnapshot(
                        id: node.id,
                        name: node.name,
                        host: node.sshHost,
                        source: .down,
                        health: HealthReport(level: .unknown, reasons: ["未启动"])
                    )
                )
            }
        }
        return out
    }

    public func nodesAwaitingCredentials() async -> [UUID] {
        var out: [UUID] = []
        for (id, runtime) in runtimes where await runtime.awaitingCredentials {
            out.append(id)
        }
        return out
    }

    @discardableResult
    public func login(nodeID: UUID, username: String, password: String) async -> Result<Void, DashboardError> {
        guard let runtime = runtimes[nodeID] else {
            return .failure(.transport("节点未启动"))
        }
        return await runtime.login(username: username, password: password)
    }

    public func signOut(nodeID: UUID) async {
        await runtimes[nodeID]?.signOut()
    }

    public func signedInUsername(nodeID: UUID) -> String? {
        SessionStore.username(for: nodeID)
    }
}
