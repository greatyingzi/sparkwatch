import AppKit
import SparkWatchCore
import SwiftUI

// Menu bar shell: one status item, a SwiftUI popover for the detail, and a
// right-click menu for the two verbs that do not belong in a card.
//
// (The first version rendered detail lines into an NSMenu. Legible, but ugly —
// a wall of monospaced text in a grey menu. The popover below is the real UI.)

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover = NSPopover()
    private var model: AppModel!
    private var timer: Timer?
    private var hosting: NSHostingController<PopoverView>!
    private var settingsWindow: NSWindow?
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // **A menu-bar app must be a single instance.**
        //
        // Two copies means two status items, and since each renders the whole
        // readout, the pair reads as "two devices" taking exactly twice the width —
        // reported by the user as 太占空间, and the cause was not the layout at all.
        // Measured 2026-10-10: `install.sh` loaded the LaunchAgent (RunAtLoad starts
        // the app) and then ran `open`, which started a *second* copy under a
        // LaunchServices job label.
        //
        // The guard lives here rather than in the installer because this is the only
        // place that covers every path: the login item, `open`, and a double click in
        // Finder. The *lower PID wins* so that two copies racing at launch cannot both
        // decide to quit — exactly one of them survives.
        if let bundleID = Bundle.main.bundleIdentifier {
            let mine = ProcessInfo.processInfo.processIdentifier
            let rivals = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != mine }
            if rivals.contains(where: { $0.processIdentifier < mine }) {
                FileHandle.standardError.write(Data(
                    "SparkWatch: 已有实例在运行（pid \(rivals.map(\.processIdentifier).sorted().first ?? 0)），本实例退出 —— 菜单栏应用必须单实例\n".utf8
                ))
                // `exit` rather than `NSApp.terminate`: this copy has no model and no
                // status item yet, and `terminate` posted a `willTerminate` that
                // force-unwrapped the still-nil model — the duplicate died with SIGTRAP
                // and left a crash report, which reads to the user as "it crashed".
                exit(0)
            }
        }

        model = AppModel(collector: ClusterCollector())

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // **Give the item an identity macOS can re-learn, and heal the off-screen case.**
        //
        // macOS remembers where a status item goes, per item identity. When the menu bar
        // was full (measured: 1393 of 1440 pt occupied) it parked ours off-screen —
        // `window = {0, -24}` — and then kept re-applying that spot forever: the item was
        // still hidden at 29 pt wide with ~47 pt of gaps free, while a brand-new item from
        // a separate probe landed on screen at {604, 876}. So the fault is the remembered
        // position, not the available space, and the fix is to take a *new* identity when
        // the old one is parked below the screen.
        let generation = UserDefaults.standard.integer(forKey: "statusItemGeneration")
        statusItem.autosaveName = "SparkWatch-\(generation)"
        if let button = statusItem.button {
            button.attributedTitle = NSAttributedString(
                string: "DGX …",
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)]
            )
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        hosting = NSHostingController(rootView: PopoverView(model: model) { [weak self] in
            self?.openSettings()
        } onTogglePause: { [weak self] in
            self?.togglePause()
        } onOpenDetail: { [weak self] nodeID in
            guard let self else { return }
            // The popover is transient; leaving it open behind the window would
            // both cover the screen and read as "the click did nothing".
            self.popover.performClose(nil)
            MainWindowManager.shared.show(model: self.model, focusing: nodeID)
        })
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = hosting
        applyThemeAppearance()

        let demoCount = CommandLine.arguments.firstIndex(of: "--demo-devices").flatMap { index in
            index + 1 < CommandLine.arguments.count ? Int(CommandLine.arguments[index + 1]) : nil
        }
        Task {
            if let demoCount {
                // Synthetic fleet: lets the layout be checked at N machines we
                // do not own before shipping to people who have them.
                model.useDemoData(nodeCount: demoCount)
                updateTitleAndSize()
                applyThemeAppearance()
                if CommandLine.arguments.contains("--detail") {
                    DetailWindowManager.shared.show(model: model)
                }
                return
            }
            await model.start()
            updateTitleAndSize()
            applyThemeAppearance()
            if CommandLine.arguments.contains("--detail") {
                DetailWindowManager.shared.show(model: model)
            }
            // First run with no config: nobody can guess the JSON, so open the
            // editor instead of showing an empty popover. `--settings` forces it
            // (handy for wiring up a new machine).
            if CommandLine.arguments.contains("--settings")
                || !FileManager.default.fileExists(atPath: SettingsStore.settingsURL.path)
            {
                openSettings()
            }
        }
        // Window-local shortcuts, so a fleet stays keyboard-reachable however
        // many machines it has (⌘1…⌘9 focus the first nine, ⌘0 shows all).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // ⌘K belongs to the main window: it is the window people work in.
            if MainWindowManager.shared.wantsKey(event),
                event.modifierFlags.contains(.command),
                event.charactersIgnoringModifiers?.lowercased() == "k"
            {
                MainWindowManager.shared.togglePalette()
                return nil
            }
            guard DetailWindowManager.shared.wantsKey(event) else { return event }
            if event.charactersIgnoringModifiers?.lowercased() == "r" {
                Task { @MainActor in await self.model.refresh() }
                return nil
            }
            return DetailWindowManager.shared.handleKey(event) ? nil : event
        }

        // The command palette's "添加机器" (and anything else that wants the
        // settings window on a particular tab) arrives as a notification, because
        // the palette is inside the window hierarchy and the window is owned here.
        NotificationCenter.default.addObserver(
            forName: .sparkwatchOpenSettingsMachines, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.openSettings() }
        }

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.model.refresh()
                self.updateTitleAndSize()
            }
        }
        healStatusItemPlacement()
    }

    /// If macOS has parked our status item off-screen, take the next identity.
    ///
    /// A parked item reports `window.frame.origin.y < 0` while `visible` stays true — the
    /// system has not "hidden" it so much as stopped drawing it where it was told to sit.
    /// Rotating the autosave name is what makes macOS place it afresh; toggling
    /// `isVisible` does not (both measured 2026-10-11).
    private func healStatusItemPlacement() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, let window = self.statusItem.button?.window else { return }
            let parked = window.frame.origin.y < 0
            guard parked else { return }
            let next = UserDefaults.standard.integer(forKey: "statusItemGeneration") + 1
            UserDefaults.standard.set(next, forKey: "statusItemGeneration")
            self.statusItem.autosaveName = "SparkWatch-\(next)"
            appendDebugIfRequested(
                popoverSize: nil, fitting: nil, budget: nil,
                note: "status item 被系统停在屏幕外 \(NSStringFromRect(window.frame))，已切换到身份 SparkWatch-\(next)"
            )
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        // A duplicate copy terminates itself inside `applicationDidFinishLaunching` (the
        // single-instance guard), long before a model exists. Without this guard,
        // `model.saveLedgers()` force-unwrapped nil and the duplicate died with SIGTRAP
        // — a crash report instead of a quiet exit (measured 2026-10-11 22:07:37).
        guard let model else { return }
        // Flush the ledgers: 8 h of GPU history and 35 days of token accounting are
        // exactly the kind of state that should survive a quit.
        model.saveLedgers()
        let collector = model.collector
        Task.detached { await collector.stop() }
    }

    /// Push the chosen theme onto the native surfaces (the popover and every
    /// open window), so the palette and the controls inside it agree. Called at
    /// launch and again whenever settings are saved — changing a theme should not
    /// need a relaunch.
    func applyThemeAppearance() {
        guard let model else { return }
        let appearance = model.theme.nsAppearance
        popover.appearance = appearance
        if let settingsWindow { settingsWindow.appearance = appearance }
        DetailWindowManager.shared.applyAppearance(appearance)
        MainWindowManager.shared.applyAppearance(appearance)
    }

    // MARK: - Status item

    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showContextMenu()
            return
        }
        togglePopover()
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        // Fresh data on open: the popover answers "what is it doing right now".
        Task {
            await model.refresh()
            updateTitleAndSize()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()

        let refresh = NSMenuItem(title: "立即刷新", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        let pause = NSMenuItem(
            title: model.isPaused ? "恢复监控" : "暂停监控",
            action: #selector(togglePause),
            keyEquivalent: "p"
        )
        pause.target = self
        menu.addItem(pause)

        let detail = NSMenuItem(
            title: "主窗口…", action: #selector(openMainWindow), keyEquivalent: "d"
        )
        detail.target = self
        menu.addItem(detail)

        let compare = NSMenuItem(
            title: "并排对比窗口…", action: #selector(openDetailWindow), keyEquivalent: ""
        )
        compare.target = self
        menu.addItem(compare)

        let recentre = NSMenuItem(
            title: "重置详情窗口位置", action: #selector(recentreDetailWindow), keyEquivalent: ""
        )
        recentre.target = self
        menu.addItem(recentre)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "设置…", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let login = NSMenuItem(
            title: "开机自动启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: ""
        )
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())

        let about = NSMenuItem(title: "关于 SparkWatch", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(
            title: "退出 SparkWatch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"
        )
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func togglePause() {
        Task { @MainActor in
            await model.togglePause()
            updateTitleAndSize()
        }
    }

    @objc private func toggleLaunchAtLogin() {
        let enable = !LoginItem.isEnabled
        if let problem = LoginItem.setEnabled(enable) {
            let alert = NSAlert()
            alert.messageText = enable ? "开机自启开启失败" : "开机自启关闭失败"
            alert.informativeText = problem
            alert.runModal()
        }
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "SparkWatch \(AppInfo.version) (\(AppInfo.build))"
        alert.informativeText = """
        DGX / GPU 节点菜单栏监控

        数据通道：官方 DGX Dashboard SSE（走 SSH 隧道）+ 推理引擎 /metrics（自动识别 vLLM / SGLang / llama.cpp / LM Studio / Ollama）+ 按需 SSH 采集
        零侵入：不在被监控的机器上安装任何东西

        配置：\(SettingsStore.settingsURL.path)
        应用位置：\(AppInfo.bundlePath)
        """
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "打开配置文件夹")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(SettingsStore.directory)
        }
    }

    @objc func openSettingsFromMenu() {
        openSettings()
    }

    @objc private func openDetailWindow() {
        DetailWindowManager.shared.show(model: model)
    }

    @objc private func openMainWindow() {
        MainWindowManager.shared.show(model: model)
    }

    @objc private func recentreDetailWindow() {
        DetailWindowManager.shared.resetPosition()
    }

    func openSettings() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        Task { @MainActor in
            let current = await model.collector.currentSettings()
            let settingsModel = SettingsModel(
                settings: current,
                previewNodes: model.nodes,
                paused: model.isPaused,
                onApply: { [weak self] updated in
                    await self?.model.apply(settings: updated)
                    await MainActor.run { self?.applyThemeAppearance() }
                },
                onPauseChange: { [weak self] paused in
                    await self?.model.setPaused(paused)
                }
            )
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 470),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "SparkWatch 设置"
            window.contentViewController = NSHostingController(rootView: SettingsView(model: settingsModel))
            window.isReleasedWhenClosed = false
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            settingsWindow = window
        }
    }

    @objc private func refreshNow() {
        Task {
            await model.refresh()
            updateTitleAndSize()
        }
    }

    private func updateTitleAndSize() {
        // Attributed so the health colours show in the menu bar itself.
        statusItem.button?.attributedTitle = model.statusBarAttributed

        // Size the popover from what it actually needs, capped by what the
        // *screen* actually allows. The old cap was a hard-coded 900 — larger
        // than the usable height of a 1440x900 display — so it could not stop a
        // squeeze, and a squeezed popover is what makes text overlap.
        let fitting = hosting.sizeThatFits(in: NSSize(width: Theme.popoverWidth, height: 1400))
        let wanted = NSSize(
            width: Theme.popoverWidth,
            height: min(max(fitting.height, 180), Theme.availableHeight)
        )
        if abs(popover.contentSize.height - wanted.height) > 1
            || popover.contentSize.width != wanted.width
        {
            popover.contentSize = wanted
        }

        // The popover cannot be screenshotted from a script (AX cannot open it),
        // so its real size is logged instead: this is the number that proves the
        // content fits the screen rather than being squeezed into it.
        appendDebugIfRequested(
            popoverSize: wanted,
            fitting: fitting,
            budget: Theme.availableHeight
        )
    }

    /// Headless verification channel: an agent with no vision tool cannot read a
    /// popover, so dump exactly what was rendered. POSIX append on purpose — the
    /// FileHandle-per-refresh version silently stopped after ~25 s, which is
    /// precisely the kind of half-truth this dump exists to prevent.
    /// "live"/"stopped"/"hidden" plus the age — the same decision the UI makes.
    private func speedStateText(_ sample: InferenceSample) -> String {
        let state = SpeedDisplay.state(
            rate: sample.decodeTPS, age: sample.decodeTPSAge, running: sample.running
        )
        let name = switch state {
        case .live: "live"
        case .stopped: "stopped"
        case .hidden: "hidden"
        }
        guard state == .stopped, let age = sample.decodeTPSAge else { return name }
        return String(format: "%@(%.0fs)", name, age)
    }

    private func appendDebugIfRequested(
        popoverSize: NSSize? = nil,
        fitting: NSSize? = nil,
        budget: CGFloat? = nil,
        note: String? = nil
    ) {
        guard let path = ProcessInfo.processInfo.environment["SPARKWATCH_DEBUG"] else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        var text = "\(stamp)\t\(model.statusBarText)\n"
        // The status item's own geometry. A menu-bar item that is not on screen has two
        // very different causes — the title is empty (width 0) or macOS hid it because
        // the bar ran out of room — and only the item itself can tell them apart:
        // `length`/`button.frame` zero means empty; a real width with an off-screen or
        // `isVisible == false` window means the system hid it.
        if let button = statusItem.button {
            text += "  statusItem: length=\(String(format: "%.1f", statusItem.length))"
                + " button=\(NSStringFromRect(button.frame))"
                + " window=\(button.window.map { NSStringFromRect($0.frame) } ?? "nil")"
                + " visible=\(button.window?.isVisible ?? false)"
                + " alpha=\(String(format: "%.2f", button.alphaValue))"
                + " titleChars=\(button.attributedTitle.string.count)\n"
        } else {
            text += "  statusItem: button=nil\n"
        }
        if let note {
            text += "  note: \(note)\n"
        }
        for snapshot in model.nodes {
            let gpu = snapshot.gpu
            let mem = gpu.memUsedPct.map { String(format: "%.0f%%", $0) } ?? "--"
            let infer = snapshot.inference.map {
                "\($0.model ?? "?") tps=\($0.decodeTPS.map { String(format: "%.1f", $0) } ?? "-")"
                + " speed=\(speedStateText($0))"
            } ?? "nil"
            if snapshot.inference?.taskRole != nil || !snapshot.processes.isEmpty {
                let procs = snapshot.processes
                    .map { "\($0.kind)\($0.headless ? "/headless" : "")\($0.nodeRank.map { "#\($0)" } ?? "")" }
                    .joined(separator: ",")
                text += "\n    procs=\(procs.isEmpty ? "-" : procs)"
            }
            text += "  · \(snapshot.name) [\(snapshot.source.label)] health=\(snapshot.health.level.label)"
            + (snapshot.health.reasons.isEmpty ? "" : "(\(snapshot.health.reasons.joined(separator: "; ")))")
            + " util=\(gpu.utilPct.map { String(format: "%.0f", $0) } ?? "-")"
            + " temp=\(gpu.tempC.map { String(format: "%.0f", $0) } ?? "-")"
            + " zone=\(snapshot.system.cpuTempC.map { String(format: "%.0f", $0) } ?? "-")"
            + "/\(snapshot.system.thermalLimitC.map { String(format: "%.0f", $0) } ?? "-")"
            + " mem=\(mem) gpuW=\(gpu.powerW.map { String(format: "%.1f", $0) } ?? "-")"
            + " clk=\(gpu.smClockMHz.map { String(format: "%.0f", $0) } ?? "-")"
            + " rawW=\(gpu.powerInstantW.map { String(format: "%.1f", $0) } ?? "-")"
            + " wholeW=\(model.powerEstimate.wholeMachineW(gpuW: gpu.powerW).map { String(format: "%.0f", $0) } ?? "-")"
            + " role=\(snapshot.inference?.taskRole ?? "-")"
            + " src=\(snapshot.inferenceSourceLabel)"
            + " cand=[\(snapshot.inferenceCandidates.map { ":\($0.port)\($0.engine.map { " \($0)" } ?? "")" }.joined(separator: ", "))]"
            + " infer=\(infer) inferErr=\((snapshot.inferenceError ?? "-").prefix(70))"
            // Which endpoint the counters actually came from, and which engine the
            // probe recognised: without these two, a stale counter cannot be told
            // apart from a slow engine.
            + " eng=\(snapshot.inference?.engine ?? "-")"
            + " url=\(snapshot.inference?.endpoint ?? "-")"
            + " via=\(snapshot.inference?.transportNote == nil ? "direct" : "ssh")"
            + " err=\((snapshot.error ?? "-").prefix(50))\n"
        }
        if let popoverSize, let fitting, let budget {
            let squeezed = fitting.height > budget + 1
            text += "  popover=\(Int(popoverSize.width))x\(Int(popoverSize.height))"
                + " 自然高度=\(Int(fitting.height)) 屏幕预算=\(Int(budget))"
                + " \(squeezed ? "⚠ 内容超出预算(会被挤压)" : "✓ 放得下, 无挤压")\n"
        }
        let activity = model.tasks.compactMap { task in
            TaskSummary.activity(for: task, in: model.nodes).map { "\(task.model):\($0.kind)=\($0.text)" }
        }.joined(separator: " | ")
        text += "  banner=[\(activity.isEmpty ? "无活动槽" : activity)]\n"
        let taskLine = "  tasks=" + (model.tasks.isEmpty ? "无" : model.tasks.map {
            "\($0.model)[\($0.topologyLabel)] nodes=\($0.nodes.joined(separator: "+")) api=\($0.apiNode ?? "-")"
        }.joined(separator: " | "))
        text += taskLine + "\n"
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
    }
}

// Scriptable bits (also handy for CI and for verifying the install):
//   --set-login-item on|off    enable/disable launch-at-login and exit
//   --print-status             print the current status-bar text and exit
if let index = CommandLine.arguments.firstIndex(of: "--set-login-item"),
    index + 1 < CommandLine.arguments.count
{
    let enable = CommandLine.arguments[index + 1] == "on"
    if let problem = LoginItem.setEnabled(enable) {
        FileHandle.standardError.write(Data("失败: \(problem)\n".utf8))
        exit(1)
    }
    print("login item \(enable ? "enabled" : "disabled") (\(LoginItem.plistURL.path))")
    exit(0)
}

let delegate = AppDelegate()
let application = NSApplication.shared

// Prints what the menu bar actually says, for every preset. The status item
// cannot be screenshotted reliably (it lives in the menu bar, and a transient
// popover closes on its own), so this is how the readout is verified from a
// terminal — and how a change to the presets is reviewed in one shot.
if CommandLine.arguments.contains("--print-status") {
    let demoCount = CommandLine.arguments.firstIndex(of: "--demo-devices").flatMap { position in
        position + 1 < CommandLine.arguments.count ? Int(CommandLine.arguments[position + 1]) : nil
    }
    application.setActivationPolicy(.accessory)
    Task { @MainActor in
        let model = AppModel(collector: ClusterCollector(), readOnlyLedgers: true)
        if let demoCount {
            model.useDemoData(nodeCount: demoCount)
        } else {
            await model.start()
            // Just wait out the first slow (SSH) probe on every machine. Trying to
            // be clever about "has the slow channel landed?" failed twice over —
            // the official stream satisfies most markers within a second, and a
            // node that has not been probed yet looks exactly like one that is
            // down. This is a diagnostic; 40 s of patience is cheaper than a dump
            // that quietly reports half the truth.
            let started = Date()
            while Date().timeIntervalSince(started) < 40 {
                await model.refresh()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        let settings = await model.collector.currentSettings()
        for task in model.tasks {
            let api = task.apiNode ?? "-"
            let quant = task.quantization ?? "-"
            print("task \(task.model) [\(task.topologyLabel)] nodes=\(task.nodes.joined(separator: "+"))"
                + " api=\(api) quant=\(quant) ctx=\(task.contextLength.map(String.init) ?? "-")")
        }
        for node in model.nodes {
            let health = node.health.reasons.isEmpty ? "-" : node.health.reasons.joined(separator: "; ")
            let gpu = node.gpu.powerW.map { String(format: "%.1fW", $0) } ?? "-"
            let tps = node.inference?.decodeTPS.map { String(format: "%.1f", $0) } ?? "-"
            let causes = node.health.causes.map(\.rawValue).joined(separator: ",")
            print("node \(node.name) source=\(node.source.rawValue) level=\(node.health.level.label)"
                + " gpu=\(gpu) tps=\(tps) causes=\(causes) [\(health)]")

            // The inference row had two bugs that were invisible from the bar: a
            // headless rank showing a stranger's model, and a source picker
            // pointing at a leftover engine. Print every input to that decision.
            let inference = node.inference
            let engine = inference?.engine ?? "-"
            let model_ = inference?.model ?? "-"
            let role = inference?.taskRole ?? "-"
            let gen = inference?.generationTokens.map { String(format: "%.0f", $0) } ?? "-"
            let prompt = inference?.promptTokens.map { String(format: "%.0f", $0) } ?? "-"
            let running = inference?.running.map { String(format: "%.0f", $0) } ?? "-"
            let prefill = inference?.prefilling.map { String(format: "%.0f", $0) } ?? "-"
            let decode = inference?.decoding.map { String(format: "%.0f", $0) } ?? "-"
            print("  inference engine=\(engine) model=\(model_) role=\(role)"
                + " source=\(node.inferenceSourceLabel) configured=\(node.inferenceConfigured)"
                + " via=\(inference?.transportNote ?? "直连")"
                + " note=\(node.inferenceNote ?? "-") err=\(node.inferenceError ?? "-")")
            // The counters behind the rate readout, so "why is there no speed"
            // can be answered from the dump instead of guessed at.
            print("    counters gen=\(gen) prompt=\(prompt) inflight=\(running)"
                + " prefill=\(prefill) decode=\(decode)")

            var candidates: [String] = []
            for candidate in node.inferenceCandidates {
                var text = "\(candidate.isLoopbackOnly ? "127.0.0.1:" : "")\(candidate.port)"
                if let engine = candidate.engine { text += "/\(engine)" }
                if let model = candidate.model { text += "·\(model)" }
                candidates.append(text)
            }
            if !candidates.isEmpty { print("  candidates " + candidates.joined(separator: ", ")) }

            var processes: [String] = []
            for process in node.processes {
                var text = process.kind.isEmpty ? "?" : process.kind
                if let model = process.servedModelName { text += "·\(model)" }
                if let port = process.port { text += ":\(port)" }
                if process.headless { text += "[headless]" }
                if let rank = process.nodeRank { text += " rank\(rank)" }
                if let count = process.nodeCount { text += "/\(count)" }
                processes.append(text)
            }
            if !processes.isEmpty { print("  processes " + processes.joined(separator: ", ")) }
        }
        for mode in StatusBarSettings.Mode.allCases {
            var bar = settings.statusBar
            bar.mode = mode
            if mode == .custom {
                // Custom is whatever the toggles say; show everything so the
                // longest possible line is visible too.
                bar.showNodeNames = true
                bar.namesOnlyWhenRelevant = false
                bar.showUtilization = true
                bar.showTemperature = true
                bar.showMemory = true
                bar.showCPU = true
                bar.showSpeed = true
                bar.showOnlineCount = true
                bar.showPower = true
            }
            let rendered = StatusBarText.text(
                for: model.nodes, settings: bar, powerEstimate: settings.powerEstimate
            )
            print("\(mode.label)\t\(rendered)")
        }
        await model.collector.stop()
        exit(0)
    }
    application.run()
    exit(0)
}

// Print the GPU history chart's *series*, not a picture of it.
//
// The chart's whole complaint history is about how it changes over time ("所有曲线都在
// 变，而不是平移"), and that is not something a screenshot can settle: the curve is
// self-similar, so a translated chart and a re-averaged one look alike. Dumping the 90
// bucket values makes the property directly checkable — run it twice inside one bucket
// period and diff.
if CommandLine.arguments.contains("--print-chart") {
    let seconds = CommandLine.arguments.firstIndex(of: "--seconds").flatMap { index in
        index + 1 < CommandLine.arguments.count ? Double(CommandLine.arguments[index + 1]) : nil
    } ?? 6
    let requested = CommandLine.arguments.firstIndex(of: "--window").flatMap { index in
        index + 1 < CommandLine.arguments.count ? Double(CommandLine.arguments[index + 1]) : nil
    } ?? 1800
    application.setActivationPolicy(.accessory)
    Task { @MainActor in
        let model = AppModel(collector: ClusterCollector(), readOnlyLedgers: true)
        await model.start()
        var elapsed = 0.0
        while elapsed < seconds {
            await model.refresh()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            elapsed += 1
        }
        guard let node = model.nodes.first else {
            print("没有可用的机器")
            exit(1)
        }
        let available = model.historySpan(for: node.id)
        let scale = GpuChartScale.resolve(requested: requested, available: available)
        let series = model.binnedHistory(
            for: node.id, window: scale.window, buckets: scale.buckets
        )
        print(String(
            format: "geometry node=%@ window=%.1f buckets=%d bucketSeconds=%.1f zoomed=%@ available=%.1f",
            node.name, scale.window, scale.buckets, scale.bucketSeconds,
            scale.zoomed ? "true" : "false", available
        ))
        func line(_ label: String, _ values: [Double?]) {
            print(label + " " + values.map { $0.map { String(format: "%.2f", $0) } ?? "-" }
                .joined(separator: ","))
        }
        line("util", series.util)
        line("power", series.power)
        line("temp", series.temp)
        line("utilLow", series.utilLow)
        line("utilHigh", series.utilHigh)
        exit(0)
    }
    application.run()
    exit(0)
}

// Headless decode benchmark.
//
// The benchmark page's action, reachable from a terminal. This is the only feature
// that sends work *to* a machine, so being able to point it at a known server (a
// local mock, or a spare box) is what makes its arithmetic verifiable **without**
// loading the engine that is currently serving real traffic.
if let index = CommandLine.arguments.firstIndex(of: "--bench"),
    index + 1 < CommandLine.arguments.count
{
    let base = CommandLine.arguments[index + 1]
    let levels = CommandLine.arguments.firstIndex(of: "--concurrency").flatMap { position in
        position + 1 < CommandLine.arguments.count
            ? CommandLine.arguments[position + 1].split(separator: ",").compactMap { Int($0) } : nil
    } ?? [1, 2]
    let maxTokens = CommandLine.arguments.firstIndex(of: "--max-tokens").flatMap { position in
        position + 1 < CommandLine.arguments.count ? Int(CommandLine.arguments[position + 1]) : nil
    } ?? 400
    let model = CommandLine.arguments.firstIndex(of: "--model").flatMap { position in
        position + 1 < CommandLine.arguments.count ? CommandLine.arguments[position + 1] : nil
    }
    application.setActivationPolicy(.accessory)
    Task {
        let options = DecodeBenchmark.Options(
            baseURL: base, model: model, maxTokens: maxTokens, concurrencyLevels: levels
        )
        print("bench: \(base) 并发=\(options.concurrencyLevels) maxTokens=\(options.maxTokens) warmup=\(options.warmup)")
        let started = Date()
        let waves = await DecodeBenchmark.run(options)
        print(String(format: "完成：%.1f 秒，%d 档", Date().timeIntervalSince(started), waves.count))
        print("  并发  流(成功/总)  单流均值  中位    最好    合计吞吐  首token    生成token")
        func f(_ value: Double?, _ digits: Int = 1) -> String {
            value.map { String(format: "%.\(digits)f", $0) } ?? "--"
        }
        for wave in waves {
            let ok = wave.streams.filter(\.ok).count
            print(
                "  \(String(format: "%4d", wave.concurrency))  \(ok)/\(wave.streams.count)"
                    + "          \(f(wave.meanDecodeTPS))    \(f(wave.medianDecodeTPS))   \(f(wave.maxDecodeTPS))"
                    + "     \(f(wave.aggregateDecodeTPS))     \(f(wave.meanTtftMs, 0)) ms"
                    + "   \(wave.totalDecodeTokens)"
            )
            for stream in wave.streams where !stream.ok {
                print("      ✕ \(stream.error ?? "未知错误")")
            }
        }
        exit(0)
    }
    application.run()
    exit(0)
}

// Offscreen preview: renders the popover (or the settings window) to a PNG
// without a window. Used for layout self-checks (a transient popover closes
// before a screenshot can catch it) and to inspect the UI without a GUI session.
/// `--theme white|light|dark|oled|system` on any preview command, so the four
/// palettes can be rendered and compared instead of described.
func previewThemeOverride() -> AppTheme? {
    guard let index = CommandLine.arguments.firstIndex(of: "--theme"),
        index + 1 < CommandLine.arguments.count
    else { return nil }
    return AppTheme(rawValue: CommandLine.arguments[index + 1].lowercased())
}

/// `--available-height 780` on any preview command: pretend the popover has this
/// much room, so the capacity rule (how many machines fit) can be verified at a
/// display size instead of whatever the headless renderer happens to report.
func applyAvailableHeightOverride() {
    guard let index = CommandLine.arguments.firstIndex(of: "--available-height"),
        index + 1 < CommandLine.arguments.count,
        let value = Double(CommandLine.arguments[index + 1])
    else { return }
    Theme.availableHeightOverride = CGFloat(value)
}
if let index = CommandLine.arguments.firstIndex(of: "--preview-settings"),
    index + 1 < CommandLine.arguments.count
{
    let path = CommandLine.arguments[index + 1]
    application.setActivationPolicy(.accessory)
    Task { @MainActor in
        let model = AppModel(collector: ClusterCollector(), readOnlyLedgers: true)
        await model.start()
        for _ in 0..<20 {
            await model.refresh()
            if model.nodes.contains(where: { $0.gpu.utilPct != nil || $0.system.memTotalBytes != nil }) {
                break
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        let settingsModel = SettingsModel(
            settings: await model.collector.currentSettings(),
            previewNodes: model.nodes,
            onApply: { _ in }
        )
        let content = SettingsView(model: settingsModel, previewMode: true)
            .background(Color(nsColor: .windowBackgroundColor))
        // Two passes: card heights equalise through a preference, so the first
        // layout is not the final one. The second pass renders at the height the
        // settled layout actually needs — rendering at a stale height clipped the
        // footer out of the image.
        var settled = NSSize(width: 400, height: 200)
        for pass in 0..<3 {
            let host = NSHostingView(rootView: content)
            let fitting = host.fittingSize
            if pass >= 1, abs(fitting.height - settled.height) < 0.5, abs(fitting.width - settled.width) < 0.5 {
                settled = fitting
                break
            }
            settled = fitting
            let renderer = ImageRenderer(
                content: content.frame(width: fitting.width, height: fitting.height)
            )
            renderer.scale = 2
            _ = renderer.nsImage
            try? await Task.sleep(for: .milliseconds(120))
        }
        // One unconditional pass: the height has already settled above. (This
        // used to be a 1-iteration loop guarding on `pass == 1`, so the branch
        // that writes the PNG could never run and the command exited 0 without
        // producing a file — a silent no-op is worse than a crash.)
        let host = NSHostingView(rootView: content)
        let fitting = host.fittingSize
        let renderer = ImageRenderer(
            content: content.frame(width: fitting.width, height: max(fitting.height, settled.height))
        )
        renderer.scale = 2
        guard let image = renderer.nsImage,
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else {
            FileHandle.standardError.write(Data("preview: render failed\n".utf8))
            exit(2)
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("settings preview: \(path) fitting=\(Int(fitting.width))x\(Int(fitting.height))pt")
        await model.collector.stop()
        exit(0)
    }
    application.run()
    exit(0)
}

// Offscreen render of the main window (sidebar + a page), for the same reason as
// --preview: an agent without a vision tool still has to be able to check a layout,
// and a window that is only ever looked at by eye is a window nobody checked.
if let index = CommandLine.arguments.firstIndex(of: "--preview-main"),
    index + 1 < CommandLine.arguments.count
{
    let path = CommandLine.arguments[index + 1]
    let demoCount = CommandLine.arguments.firstIndex(of: "--demo-devices").flatMap { position in
        position + 1 < CommandLine.arguments.count ? Int(CommandLine.arguments[position + 1]) : nil
    }
    let pageArgument = CommandLine.arguments.firstIndex(of: "--page").flatMap { position in
        position + 1 < CommandLine.arguments.count ? CommandLine.arguments[position + 1] : nil
    }
    let width = CommandLine.arguments.firstIndex(of: "--width").flatMap { position in
        position + 1 < CommandLine.arguments.count ? Double(CommandLine.arguments[position + 1]) : nil
    } ?? 1240
    let height = CommandLine.arguments.firstIndex(of: "--height").flatMap { position in
        position + 1 < CommandLine.arguments.count ? Double(CommandLine.arguments[position + 1]) : nil
    } ?? 900
    application.setActivationPolicy(.accessory)
    Task { @MainActor in
        let model = AppModel(collector: ClusterCollector(), readOnlyLedgers: true)
        // `--seconds N` forces a real collection window: the ledgers integrate over
        // time (energy is minutes, history is sampled per tick), so a render that
        // returns as soon as one sample lands can only ever show zeros.
        let collectSeconds = CommandLine.arguments.firstIndex(of: "--seconds").flatMap { position in
            position + 1 < CommandLine.arguments.count ? Double(CommandLine.arguments[position + 1]) : nil
        }
        if let demoCount {
            model.useDemoData(nodeCount: demoCount)
        } else {
            await model.start()
            let deadline = Date().addingTimeInterval(collectSeconds ?? 40)
            var refreshCount = 0
            while Date() < deadline {
                await model.refresh()
                refreshCount += 1
                if collectSeconds == nil,
                    model.nodes.allSatisfy({ $0.gpu.utilPct != nil || $0.source == .down }),
                    !model.tasks.isEmpty
                {
                    break
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            if let node = model.nodes.first {
                print("  collect: refresh=\(refreshCount) 次 history=\(model.historyPoints(for: node.id, window: 86_400).count) 点"
                    + " watts=\(model.energySnapshot?.currentWatts.map { String(format: "%.0f", $0) } ?? "-")"
                    + " coverage24h=\(model.energySnapshot.map { String(format: "%.3f", $0.coverage24h) } ?? "-")")
            }
        }
        if let theme = previewThemeOverride() {
            model.overrideTheme(theme)
            if let appearance = theme.nsAppearance { NSAppearance.current = appearance }
        }
        let state = MainWindowState()
        switch pageArgument {
        case "energy": state.page = .energy
        case "tokens": state.page = .tokens
        case "activity": state.page = .activity
        case "benchmarks": state.page = .benchmarks
        case "machine": if let first = model.nodes.first { state.page = .machine(first.id) }
        default: state.page = .overview
        }
        let content = MainWindowView(model: model, state: state, onOpenSettings: {}, scrolls: false)
            .frame(width: width, height: height)
        let host = NSHostingView(rootView: content)
        _ = host.fittingSize
        try? await Task.sleep(for: .milliseconds(200))
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage,
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else {
            FileHandle.standardError.write(Data("main preview: render failed\n".utf8))
            exit(2)
        }
        try? png.write(to: URL(fileURLWithPath: path))
        let energy = model.energySnapshot
        print(
            "main preview: \(path) page=\(String(describing: state.page)) rendered=\(Int(image.size.width))x\(Int(image.size.height))pt"
                + " nodes=\(model.nodes.count) events=\(model.events.count)"
                + " energy24h=\(energy.map { String(format: "%.2f", $0.energy24hKWh) } ?? "-")kWh"
                + " tokens=\(compactTokens(model.tokenTotals.completion))"
                + " history=\(model.nodes.first.map { model.historyPoints(for: $0.id, window: 3600).count } ?? 0) 点"
        )
        model.saveLedgers()
        await model.collector.stop()
        exit(0)
    }
    application.run()
    exit(0)
}

// Offscreen render of the detail window, for the same reason as --preview: an
// agent with no vision tool still has to be able to check a layout at N machines.
if let index = CommandLine.arguments.firstIndex(of: "--preview-detail"),
    index + 1 < CommandLine.arguments.count
{
    let path = CommandLine.arguments[index + 1]
    // No --demo-devices: render the real fleet (the slow channel needs a round).
    let demoCount = CommandLine.arguments.firstIndex(of: "--demo-devices").flatMap { position in
        position + 1 < CommandLine.arguments.count ? Int(CommandLine.arguments[position + 1]) : nil
    }
    let windowWidth = CommandLine.arguments.firstIndex(of: "--width").flatMap { position in
        position + 1 < CommandLine.arguments.count ? Double(CommandLine.arguments[position + 1]) : nil
    } ?? 1020
    Task { @MainActor in
        let model = AppModel(collector: ClusterCollector(), readOnlyLedgers: true)
        if let demoCount {
            model.useDemoData(nodeCount: demoCount)
        } else {
            await model.start()
            // Let the first slow probe land so the columns show real detail.
            let deadline = Date().addingTimeInterval(40)
            while Date() < deadline {
                await model.refresh()
                if model.nodes.allSatisfy({ !$0.system.containers.isEmpty || $0.system.memAvailableBytes != nil }),
                    !model.tasks.isEmpty
                {
                    break
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        if let theme = previewThemeOverride() {
            model.overrideTheme(theme)
            if let appearance = theme.nsAppearance { NSAppearance.current = appearance }
        }
        let state = DetailState()
        state.labels = model.nodes.map { ($0.id, $0.name) }
        let content = DetailView(model: model, state: state, onClose: {}, scrolls: false)
            .frame(width: windowWidth, height: 760)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: content)
        _ = host.fittingSize
        try? await Task.sleep(for: .milliseconds(150))
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage,
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else {
            FileHandle.standardError.write(Data("detail preview: render failed\n".utf8))
            exit(2)
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("detail preview: \(path) devices=\(demoCount.map(String.init) ?? "-") rendered=\(Int(image.size.width))x\(Int(image.size.height))pt")
        exit(0)
    }
    application.setActivationPolicy(.accessory)
    application.run()
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--preview"),
    index + 1 < CommandLine.arguments.count
{
    let path = CommandLine.arguments[index + 1]
    let seconds = CommandLine.arguments.firstIndex(of: "--seconds").flatMap { position in
        position + 1 < CommandLine.arguments.count ? Double(CommandLine.arguments[position + 1]) : nil
    } ?? 12
    let demoCount = CommandLine.arguments.firstIndex(of: "--demo-devices").flatMap { index in
        index + 1 < CommandLine.arguments.count ? Int(CommandLine.arguments[index + 1]) : nil
    }
    application.setActivationPolicy(.accessory)
    Task { @MainActor in
        let startedAt = Date()
        let model = AppModel(collector: ClusterCollector(), readOnlyLedgers: true)
        if let demoCount {
            // Synthetic fleet: renders N machines (any N) without needing them.
            model.useDemoData(nodeCount: demoCount)
        } else {
            await model.start()
        }
        // The renderer reads the palette off the model, and the *native* chrome
        // off NSAppearance.current — set both so `--theme` means something.
        if let theme = previewThemeOverride() {
            model.overrideTheme(theme)
            if let appearance = theme.nsAppearance { NSAppearance.current = appearance }
        }
        let deadline = Date().addingTimeInterval(demoCount == nil ? seconds : 1)
        while Date() < deadline {
            await model.refresh()
            // Wait for real numbers, not the first empty frame.
            // Every machine, not just one: rendering while a box is still on
            // its first sample draws a "连接中" card that misrepresents the UI.
            let hasData = model.nodes.allSatisfy {
                $0.gpu.utilPct != nil || $0.system.memTotalBytes != nil || $0.source == .down
            }
            // The task banner comes from the slow channel's process table; give
            // it the first probe window before declaring the layout settled.
            //
            // "tasks is non-empty" is not enough: a one-member deployment renders
            // a banner that says TP2 with a single role chip, and the machine that
            // has not been read yet shows an inference row it should not have —
            // a rank that has not been probed is indistinguishable from a rank
            // that is not running. Wait until every machine's slow probe has
            // landed (`diskUsedBytes` only ever comes from the SSH probe; a node
            // that finished failing reports `!connecting`).
            let slowLanded = model.nodes.allSatisfy {
                $0.system.diskUsedBytes != nil || (!$0.connecting && $0.source == .down)
            }
            let topologySettled = (slowLanded && !model.nodes.isEmpty)
                || Date() > deadline.addingTimeInterval(-(seconds - 22))
            // …and for every configured inference endpoint to resolve either way
            // (sample or error), otherwise the render shows "probing…" and hides
            // what the card will actually look like.
            let inferenceSettled = model.nodes.allSatisfy {
                !$0.inferenceConfigured || $0.inference != nil || $0.inferenceError != nil
            }
            if hasData, inferenceSettled, topologySettled {
                try? await Task.sleep(for: .seconds(2))
                break
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        let content = PopoverView(model: model)
            .background(Palette.chrome(model.theme, dark: true))
        applyAvailableHeightOverride()

        // Two passes: the first lets the card-height preferences settle (cards
        // equalise to the tallest), the second renders what the user will see.
        // ImageRenderer lays out once, so a single pass would draw the
        // pre-settled layout and clip the difference.
        // Two passes: card heights equalise through a preference, so the first
        // layout is not the final one. The second pass renders at the height the
        // settled layout actually needs — rendering at a stale height clipped the
        // footer out of the image.
        var settled = NSSize(width: 400, height: 200)
        for pass in 0..<3 {
            let host = NSHostingView(rootView: content)
            let fitting = host.fittingSize
            if pass >= 1, abs(fitting.height - settled.height) < 0.5, abs(fitting.width - settled.width) < 0.5 {
                settled = fitting
                break
            }
            settled = fitting
            let renderer = ImageRenderer(
                content: content.frame(width: fitting.width, height: fitting.height)
            )
            renderer.scale = 2
            _ = renderer.nsImage
            try? await Task.sleep(for: .milliseconds(120))
        }
        for _ in 0..<1 {
            let host = NSHostingView(rootView: content)
            let fitting = host.fittingSize
            let renderer = ImageRenderer(
                content: content.frame(width: fitting.width, height: max(fitting.height, settled.height))
            )
            renderer.scale = 2
            guard let image = renderer.nsImage,
                let tiff = image.tiffRepresentation,
                let bitmap = NSBitmapImageRep(data: tiff),
                let png = bitmap.representation(using: .png, properties: [:])
            else {
                FileHandle.standardError.write(Data("preview: render failed\n".utf8))
                exit(2)
            }
            try? png.write(to: URL(fileURLWithPath: path))
            // Report *when* the frame was taken and what the topology looked like
            // at that instant: a preview that renders early shows a one-member
            // deployment, and nothing in the image says whether that is the truth
            // or a race.
            //
            // Also dumps the slow-channel facts that have no place in a picture
            // (throughput, kernel counters, tailnet path) — a verification channel
            // for exactly the things a screenshot cannot show.
            let waited = String(format: "%.1f", Date().timeIntervalSince(startedAt))
            let topology = model.tasks.map {
                "\($0.model)[\($0.topologyLabel)] nodes=\($0.nodes.joined(separator: "+"))"
            }.joined(separator: " | ")
            for node in model.nodes {
                let split = node.system.memorySplit()
                let gb = { (bytes: UInt64?) in
                    bytes.map { String(format: "%.1f", Double($0) / 1_073_741_824) } ?? "-"
                }
                let net = node.system.network.primaryInterface
                let netLine = net.map {
                    "\($0.name) ↑\(Int($0.txBytesPerSec / 1024))K/s ↓\(Int($0.rxBytesPerSec / 1024))K/s"
                        + ($0.linkSpeedMbps.map { " \(Int($0))Mb" } ?? "")
                } ?? "无"
                let disk = (node.system.diskReadBytesPerSec, node.system.diskWriteBytesPerSec)
                let kernel = node.system.kernelErrors
                let inference = node.inference
                print(
                    "  slow \(node.name): gpuAlloc=\(gb(split.gpu))G system=\(gb(split.system))G free=\(gb(split.free))G"
                        + " | net=\(netLine)"
                        + " | disk r=\(Int((disk.0 ?? 0) / 1024))K/s w=\(Int((disk.1 ?? 0) / 1024))K/s"
                        + " | throttle=\(node.gpu.throttle?.label ?? "-")"
                        + " clock=\(node.gpu.smClockMHz.map { String(format: "%.0f", $0) } ?? "-")"
                        + " limit=\(node.gpu.powerLimitW.map { String(format: "%.0f", $0) } ?? "N/A")"
                        + " | kernel(xid=\(kernel.xid) oom=\(kernel.oomKills) nverr=\(kernel.nvErrNoMemory)"
                        + " readable=\(kernel.available) incident=\(node.system.incidentActive))"
                        + " | tailnet=\(node.system.tailnet.map { "\($0.online ? "online" : "offline") via \($0.pathLabel) \($0.ip ?? "-")" } ?? "不可读")"
                )
                // The engine's own latency percentiles: printed because they are the
                // one group of numbers with no other way to check them offscreen.
                print(
                    "    engine \(node.name): \(inference?.engine ?? "-")"
                        + " ttft=\(inference?.ttftMeanSeconds.map { String(format: "%.2f", $0) } ?? "-")s"
                        + " ttftP95=\(inference?.ttftP95Seconds.map { String(format: "%.2f", $0) } ?? "-")s"
                        + " e2eP95=\(inference?.e2eP95Seconds.map { String(format: "%.1f", $0) } ?? "-")s"
                        + " itlP95=\(inference?.itlP95Seconds.map { String(format: "%.0f", $0 * 1000) } ?? "-")ms"
                        + " kv=\(inference?.kvUsagePct.map { String(format: "%.1f", $0) } ?? "-")%"
                        + " cacheHit=\(inference?.cacheHitPct.map { String(format: "%.1f", $0) } ?? "-")%"
                        + " mtp=\(inference?.acceptancePct.map { String(format: "%.1f", $0) } ?? "-")%"
                        + " procs=\(node.system.gpuProcesses.count)"
                )
            }
            print("preview written: \(path) fitting=\(Int(fitting.width))x\(Int(fitting.height))pt"
                + " rendered=\(Int(image.size.width))x\(Int(image.size.height))pt"
                + " available=\(Int(Theme.availableHeight)) 容量=\(Theme.cardCapacity()) 台"
                + " 显示=\(min(model.nodes.count, Theme.cardCapacity())) 共\(model.nodes.count)台"
                + " waited=\(waited)s tasks=\(topology.isEmpty ? "无" : topology)")
        }
        await model.collector.stop()
        exit(0)
    }
    application.run()
    exit(0)
}

application.delegate = delegate
application.run()
