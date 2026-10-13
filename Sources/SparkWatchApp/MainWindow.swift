import AppKit
import SparkWatchCore
import SwiftUI

/// The main window: the tier that holds *everything*, as opposed to the popover
/// (which holds what fits) and the menu bar (one line).
///
/// Why a window at all, when the popover already exists: a popover cannot scroll,
/// cannot be resized and cannot stay open while you work. Everything that needs
/// more than a glance — history, per-machine detail, the ledgers, benchmarks —
/// has nowhere to live in it. This is that place, and the sidebar is its index:
/// one row per machine, plus the fleet-level pages.
enum MainPage: Equatable, Hashable {
    case overview
    case machine(UUID)
    case energy
    case tokens
    case activity
    case benchmarks

    var title: String {
        switch self {
        case .overview: "概览"
        case .machine: "机器详情"
        case .energy: "能耗"
        case .tokens: "Token 统计"
        case .activity: "活动"
        case .benchmarks: "基准测试"
        }
    }
}

@MainActor
final class MainWindowState: ObservableObject {
    @Published var page: MainPage = .overview
    /// ⌘K palette visibility, owned here so the sidebar's trigger and the window's
    /// key equivalent drive the same switch.
    @Published var paletteOpen = false
}

@MainActor
final class MainWindowManager {
    static let shared = MainWindowManager()

    private var window: NSWindow?
    private var state: MainWindowState?
    private weak var model: AppModel?

    var isVisible: Bool { window?.isVisible == true }

    func show(model: AppModel, page: MainPage? = nil, focusing nodeID: UUID? = nil) {
        self.model = model
        if window == nil { build(model: model) }
        if let page { state?.page = page }
        else if let nodeID { state?.page = .machine(nodeID) }
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() { window?.close() }

    /// ⌘K, routed from the app delegate's key monitor (which owns the "which
    /// window is key" decision).
    func togglePalette() {
        guard let state else { return }
        state.paletteOpen.toggle()
    }

    func applyAppearance(_ appearance: NSAppearance?) {
        window?.appearance = appearance
    }

    /// Whether a key event belongs to this window (⌘K / ⌘1…⌘9 are handled in
    /// `AppDelegate`'s monitor, which routes by which window is key).
    func wantsKey(_ event: NSEvent) -> Bool {
        window?.isKeyWindow == true && window?.isVisible == true
    }

    private func build(model: AppModel) {
        let state = MainWindowState()
        self.state = state
        let hosting = NSHostingController(
            rootView: MainWindowView(model: model, state: state, onOpenSettings: {
                NSApp.sendAction(#selector(AppDelegate.openSettingsFromMenu), to: nil, from: nil)
            })
        )
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(
            width: min(1240, visible.width - 100),
            height: min(820, visible.height - 120)
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "SparkWatch"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 860, height: 520)
        window.contentViewController = hosting
        window.setContentSize(size)
        let hadSavedFrame = UserDefaults.standard.string(forKey: "NSWindow Frame SparkWatchMain") != nil
        window.setFrameAutosaveName("SparkWatchMain")
        if !hadSavedFrame { window.center() }
        self.window = window
    }
}

// MARK: - Shell

struct MainWindowView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: MainWindowState
    var onOpenSettings: () -> Void
    /// Offscreen rendering (`ImageRenderer`) gives a `ScrollView` no size, so the
    /// preview path renders the page without the scroll container. Same trick — and
    /// the same reason — as the detail window's `scrolls` flag: without it a preview
    /// silently shows an empty content area next to a full sidebar, and "the render
    /// is blank" is indistinguishable from "the page is blank".
    var scrolls: Bool = true

    @Environment(\.colorScheme) private var colorScheme

    private var palette: Palette { Palette.of(model.theme, dark: colorScheme == .dark) }

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model, state: state, palette: palette, onOpenSettings: onOpenSettings)
                .frame(width: 248)
            Divider()
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Palette.chrome(model.theme, dark: colorScheme == .dark, translucent: false))
        .overlay {
            if state.paletteOpen {
                CommandPalette(model: model, state: state, palette: palette)
            }
        }
    }

    @ViewBuilder
    private var page: some View {
        if scrolls {
            ScrollView { pageContent }
        } else {
            pageContent
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        switch state.page {
        case .overview:
            OverviewPage(model: model, state: state, palette: palette, onOpenSettings: onOpenSettings)
        case let .machine(id):
            if let node = model.nodes.first(where: { $0.id == id }) {
                MachinePage(model: model, node: node, palette: palette)
            } else {
                MissingMachine(palette: palette) { state.page = .overview }
            }
        case .energy, .tokens, .activity, .benchmarks:
            FleetPage(model: model, page: state.page, palette: palette)
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: MainWindowState
    var palette: Palette
    var onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            brand
            jump
            sparks
            workspace
            Spacer(minLength: 0)
            foot
        }
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(
            palette.surface.opacity(0.5)
        )
    }

    private var brand: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(palette.accent)
                .frame(width: 26, height: 26)
                .overlay(Text("⌁").font(.system(size: 14, weight: .heavy)).foregroundStyle(palette.onAccent))
            Text("SparkWatch")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
    }

    private var jump: some View {
        Button {
            state.paletteOpen = true
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 10))
                Text("跳转到…").font(.system(size: 12.5, design: .rounded))
                Spacer(minLength: 0)
                Text("⌘K")
                    .font(.system(size: 10, design: .monospaced))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(palette.border, lineWidth: 1)
                    )
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(palette.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var sparks: some View {
        VStack(alignment: .leading, spacing: 3) {
            sectionLabel("机器", trailing: "\(model.nodes.count)")
            ForEach(model.nodes) { node in
                Button {
                    state.page = .machine(node.id)
                } label: {
                    HStack(spacing: 8) {
                        StatusDot(level: node.health.level, palette: palette)
                        Text(node.name)
                            .font(.system(size: 13, design: .rounded))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(subLabel(node))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(node.inference?.decodeTPS != nil ? palette.ok : .secondary)
                            .lineLimit(1)
                            // 侧栏窄，速度是「数字+单位」一体的，缩字号比截断可读。
                            .minimumScaleFactor(0.85)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(state.page == .machine(node.id) ? palette.surfaceHover : .clear)
                    )
                    .overlay(alignment: .leading) {
                        if state.page == .machine(node.id) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(palette.accent)
                                .frame(width: 2)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(state.page == .machine(node.id) ? AnyShapeStyle(palette.textStrong) : AnyShapeStyle(palette.mutedStrong))
            }
            if model.nodes.isEmpty {
                Text("还没有机器 · 用 + 添加")
                    .font(.system(size: 11.5, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 9)
            }
        }
    }

    /// The rail's one-glance column: what the machine is doing, in three
    /// characters. A machine that is down says so; a busy one shows its rate.
    private func subLabel(_ node: NodeSnapshot) -> String {
        if node.connecting { return "连接中" }
        if node.source == .down { return "off" }
        if let running = node.inference?.running, running == 0 { return "—" }
        if let tps = node.inference?.decodeTPS, tps > 0.5 {
            return tps >= 100 ? String(format: "%.0f/s", tps) : String(format: "%.1f/s", tps)
        }
        if let util = node.gpu.utilPct { return String(format: "%.0f%%", util) }
        return "—"
    }

    private var workspace: some View {
        VStack(alignment: .leading, spacing: 3) {
            sectionLabel("机队", trailing: nil)
            ForEach(workspacePages, id: \.page) { entry in
                railItem(entry.page, icon: entry.icon)
            }
        }
    }

    private var workspacePages: [(page: MainPage, icon: String)] {
        [
            (.overview, "square.grid.2x2"),
            (.energy, "bolt"),
            (.tokens, "circle.hexagongrid"),
            (.activity, "list.bullet"),
            (.benchmarks, "chart.bar.xaxis"),
        ]
    }

    private func railItem(_ page: MainPage, icon: String) -> some View {
        Button {
            state.page = page
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 11)).frame(width: 15)
                Text(page.title).font(.system(size: 13, design: .rounded))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(state.page == page ? palette.surfaceHover : .clear)
            )
            .overlay(alignment: .leading) {
                if state.page == page {
                    RoundedRectangle(cornerRadius: 2).fill(palette.accent).frame(width: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(state.page == page ? AnyShapeStyle(palette.textStrong) : AnyShapeStyle(palette.mutedStrong))
    }

    private var foot: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onOpenSettings) {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape").font(.system(size: 11)).frame(width: 15)
                    Text("设置").font(.system(size: 13, design: .rounded))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.mutedStrong)

            // The same "Live · N s" pill the popover header shows. It answers the
            // first question anyone asks of a frozen dashboard: is this thing
            // actually running?
            HStack(spacing: 7) {
                Circle()
                    .fill(model.isPaused ? palette.warn : palette.ok)
                    .frame(width: 7, height: 7)
                Text(model.isPaused ? "已暂停" : String(format: "Live · %.0f s poll", model.pollSeconds))
                    .font(.system(size: 11.5, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(palette.border, lineWidth: 1)
            )
        }
    }

    private func sectionLabel(_ text: String, trailing: String?) -> some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.bottom, 2)
    }
}

// MARK: - Overview

struct OverviewPage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: MainWindowState
    var palette: Palette
    var onOpenSettings: () -> Void

    private var alive: Int { model.nodes.filter { $0.source != .down }.count }

    private var fleetDecode: Double {
        model.nodes.reduce(0) { $0 + ($1.inference?.decodeTPS ?? 0) }
    }

    private var fleetWatts: Double {
        model.nodes.reduce(0) { total, node in
            total + (model.powerEstimate.wholeMachineW(gpuW: node.gpu.powerW) ?? 0)
        }
    }

    private var memory: (used: Double, total: Double) {
        model.nodes.reduce(into: (0.0, 0.0)) { result, node in
            result.0 += Double(node.gpu.memUsedBytes ?? 0)
            result.1 += Double(node.gpu.memTotalBytes ?? 0)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let alert = alertSummary { alertStrip(alert) }
            kpis
            Text("机器")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(.tertiary)
            cardGrid
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("概览")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .tracking(-0.5)
                HStack(spacing: 8) {
                    Text("\(model.nodes.count) 台机器")
                    Circle().fill(alive == model.nodes.count ? palette.ok : palette.warn).frame(width: 6, height: 6)
                    Text("\(alive)/\(model.nodes.count) 在线")
                    if memory.total > 0 {
                        Text("·")
                        Text(String(format: "统一内存 %.0f / %.0f GB",
                                    memory.used / 1_073_741_824, memory.total / 1_073_741_824))
                    }
                    if let task = model.tasks.first {
                        Text("·")
                        Text("\(task.model) · \(task.topologyLabel)")
                            .lineLimit(1)
                    }
                }
                .font(.system(size: 12.5, design: .rounded))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                if model.isPaused {
                    Button("恢复监控") { Task { await model.togglePause() } }
                        .controlSize(.small)
                } else {
                    Button("暂停监控") { Task { await model.togglePause() } }
                        .controlSize(.small)
                }
                Button("设置…") { onOpenSettings() }
                    .controlSize(.small)
            }
        }
    }

    private var kpis: some View {
        HStack(alignment: .top, spacing: 14) {
            kpiTile(
                label: "机队解码",
                value: fleetDecode > 0 ? String(format: "%.1f", fleetDecode) : "--",
                unit: "tok/s",
                foot: fleetDecode > 0 ? "各机实测速率之和" : "当前没有引擎在生成",
                tint: palette.accent,
                series: model.nodes.compactMap { $0.inference?.decodeTPS }
            )
            kpiTile(
                label: "机队功耗",
                value: String(format: "%.0f", fleetWatts),
                unit: "W",
                foot: String(format: "GPU 实测 %.0f W + CPU/外设估算",
                             model.nodes.reduce(0) { $0 + ($1.gpu.powerW ?? 0) }),
                tint: palette.violet,
                series: model.nodes.compactMap { $0.gpu.powerW }
            )
            kpiTile(
                label: "统一内存在用",
                value: memory.total > 0 ? String(format: "%.0f", memory.used / 1_073_741_824) : "--",
                unit: "GB",
                foot: memory.total > 0
                    ? String(format: "占池 %.0f%% · 可用 %.0f GB",
                             memory.used / memory.total * 100,
                             (memory.total - memory.used) / 1_073_741_824)
                    : "等待第一帧遥测",
                tint: palette.info,
                series: []
            )
            kpiTile(
                label: "引擎状态",
                value: model.nodes.compactMap { $0.inference?.running }.isEmpty
                    ? "--" : String(format: "%.0f", model.nodes.compactMap { $0.inference?.running }.reduce(0, +)),
                unit: "在跑请求",
                foot: kvFoot,
                tint: palette.ok,
                series: []
            )
        }
    }

    private var kvFoot: String {
        let parts = model.nodes.compactMap { node -> String? in
            guard let kv = node.inference?.kvUsagePct else { return nil }
            return String(format: "%@ KV %.0f%%", node.name, kv)
        }
        return parts.isEmpty ? "引擎未上报 KV 占用" : parts.joined(separator: " · ")
    }

    private func kpiTile(
        label: String, value: String, unit: String, foot: String, tint: Color, series: [Double]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .tracking(1)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            // 数字 + 单位必须同处一行：KPI 瓦片是三个平分宽度，窗口一窄 34 pt 的数
            // 就会被拆成两行 —— 实测 640 pt 下旧写法的数字在 y=471、单位 `tok/s` 掉到
            // y=504（差一整行高），这就是用户报的「token 速度换了行」。走共用的 NumberUnit。
            NumberUnit(
                value: value,
                unit: unit,
                size: 34,
                unitSize: 12,
                tint: palette.textStrong,
                weight: .semibold,
                design: .rounded,
                tracking: -1
            )
            if series.count > 1 {
                Sparkline(values: series, tint: tint)
                    .frame(height: 30)
            }
            Text(foot)
                .font(.system(size: 11.5, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(palette.border, lineWidth: 1)
        )
    }

    /// The worst thing in the fleet, said once, in one sentence — with the machine
    /// named, because "memory is tight" without a name is not actionable.
    private var alertSummary: (name: String, text: String, bad: Bool)? {
        if let down = model.nodes.first(where: { $0.source == .down }) {
            return (down.name, "主机不可达（SSH 与面板都不通）", true)
        }
        if let node = model.nodes.first(where: { $0.health.level == .critical }),
            let reason = node.health.reasons.first
        {
            return (node.name, reason, true)
        }
        if let node = model.nodes.first(where: { $0.health.level == .warning }),
            let reason = node.health.reasons.first
        {
            return (node.name, reason, false)
        }
        return nil
    }

    private func alertStrip(_ alert: (name: String, text: String, bad: Bool)) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 13))
            Text(alert.name).font(.system(size: 12.5, weight: .semibold, design: .rounded))
            Text(alert.text).font(.system(size: 12.5, design: .rounded))
            Spacer(minLength: 0)
            Button("打开") {
                if let node = model.nodes.first(where: { $0.name == alert.name }) {
                    state.page = .machine(node.id)
                }
            }
            .controlSize(.small)
        }
        .foregroundStyle(alert.bad ? palette.danger : palette.warn)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill((alert.bad ? palette.danger : palette.warn).opacity(0.11))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder((alert.bad ? palette.danger : palette.warn).opacity(0.35), lineWidth: 1)
        )
    }

    private var cardGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 340, maximum: 520), spacing: 12)],
            alignment: .leading,
            spacing: 12
        ) {
            ForEach(model.nodes) { node in
                NodeCard(
                    snapshot: node,
                    history: model.history[node.id] ?? AppModel.History(),
                    powerWindowSeconds: model.powerWindowSeconds,
                    inferenceSource: model.inferenceSource(for: node.id),
                    onChooseSource: { source in
                        Task { await model.setInferenceSource(nodeID: node.id, source: source) }
                    },
                    powerEstimate: model.powerEstimate,
                    palette: palette,
                    onLogin: {},
                    onSignOut: {}
                )
            }
        }
    }
}

// MARK: - Machine page

struct MachinePage: View {
    @ObservedObject var model: AppModel
    var node: NodeSnapshot
    var palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            GpuHistoryChart(model: model, nodeID: node.id, palette: palette)
            MachinePanels(model: model, node: node, palette: palette)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                StatusDot(level: node.health.level, palette: palette)
                Text(node.name)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .tracking(-0.5)
                if let role = node.inference?.taskRole {
                    Chip(text: role, tint: palette.accent)
                }
                if let engine = node.inference?.engine {
                    Chip(text: engine, tint: palette.violet)
                }
                if let uptime = node.system.uptimeSeconds {
                    Chip(text: uptimeLabel(uptime), tint: .secondary)
                }
                Spacer(minLength: 0)
                ShutdownButton(
                    node: node,
                    config: model.nodeConfigs.first { $0.name == node.name || $0.sshHost == node.host },
                    palette: palette
                ) { message in
                    model.noteAction(message, severity: .warn, kind: "node.shutdown", node: node)
                }
                Button("并排对比") {
                    DetailWindowManager.shared.show(model: model, focusing: node.id)
                }
                .controlSize(.small)
            }
            HStack(spacing: 8) {
                Text(node.host).font(.system(size: 12.5, design: .monospaced))
                if let ip = node.system.tailnet?.ip {
                    Text("·")
                    Text(ip).font(.system(size: 12.5, design: .monospaced))
                }
                if let cores = node.system.cpuCores {
                    Text("·")
                    Text("\(cores) 核")
                }
                if let total = node.system.memTotalBytes {
                    Text("·")
                    Text(String(format: "%.0f GB 统一内存", Double(total) / 1_073_741_824))
                }
            }
            .font(.system(size: 12.5, design: .rounded))
            .foregroundStyle(.secondary)
        }
    }

    private func uptimeLabel(_ seconds: Double) -> String {
        let days = seconds / 86_400
        if days >= 1 { return String(format: "运行 %.1f 天", days) }
        return String(format: "运行 %.0f 小时", seconds / 3600)
    }
}

struct MissingMachine: View {
    var palette: Palette
    var onBack: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text("这台机器已不在配置里")
                .font(.system(size: 14, design: .rounded))
            Button("回到概览", action: onBack).controlSize(.small)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
        .foregroundStyle(.secondary)
    }
}
