import AppKit
import SparkWatchCore
import SwiftUI

/// Settings window: add/edit/remove machines, find their inference endpoint,
/// verify the whole chain, and shape the status bar. No JSON editing required.
@MainActor
final class SettingsModel: ObservableObject {
    @Published var settings: AppSettings
    @Published var scans: [UUID: [Diagnostics.ScanHit]] = [:]
    @Published var checks: [UUID: [Diagnostics.CheckResult]] = [:]
    @Published var passwords: [UUID: String] = [:]
    @Published var busy: UUID?
    @Published var message: String?
    @Published var pausedLocal = false

    /// Live snapshots, so the status-bar preview shows the real readout.
    let previewNodes: [NodeSnapshot]

    private let onApply: (AppSettings) async -> Void
    private let onPauseChange: (Bool) async -> Void

    init(
        settings: AppSettings,
        previewNodes: [NodeSnapshot],
        paused: Bool = false,
        onApply: @escaping (AppSettings) async -> Void,
        onPauseChange: @escaping (Bool) async -> Void = { _ in }
    ) {
        self.settings = settings
        self.previewNodes = previewNodes
        self.pausedLocal = paused
        self.onApply = onApply
        self.onPauseChange = onPauseChange
    }

    var statusBarPreview: String {
        AppModel.summary(
            for: previewNodes,
            settings: settings.statusBar,
            powerEstimate: settings.powerEstimate
        )
    }

    /// Lowest free local port above 19100 — the per-node forward target.
    func nextLocalPort() -> Int {
        let used = Set(settings.nodes.map(\.dashboardLocalPort))
        var port = 19100
        while used.contains(port) { port += 1 }
        return port
    }

    func addNode() {
        settings.nodes.append(
            NodeConfig(
                name: "node-\(settings.nodes.count + 1)",
                sshHost: "",
                sshUser: NSUserName(),
                dashboardLocalPort: nextLocalPort()
            )
        )
    }

    func remove(_ node: NodeConfig) {
        settings.nodes.removeAll { $0.id == node.id }
        scans[node.id] = nil
        checks[node.id] = nil
    }

    func scan(_ node: NodeConfig) async {
        guard !node.sshHost.isEmpty else { return }
        busy = node.id
        message = "正在 \(node.sshHost) 上扫描推理端口…"
        // Enumerate what the box actually listens on, then identify each port —
        // a fixed port list misses container-mapped engines.
        let hits = await Diagnostics.discoverInferenceEndpoints(user: node.sshUser, host: node.sshHost)
        scans[node.id] = hits
        message = hits.isEmpty
            ? "\(node.name)：没发现推理服务，可手动填 URL"
            : "\(node.name)：发现 \(hits.count) 个端点"
        busy = nil
    }

    func check(_ node: NodeConfig) async {
        guard !node.sshHost.isEmpty else { return }
        busy = node.id
        message = "体检 \(node.name)…"
        checks[node.id] = await Diagnostics.checkNode(node, password: passwords[node.id])
        message = nil
        busy = nil
    }

    func setPausedFromSettings(_ paused: Bool) async {
        await onPauseChange(paused)
    }

    func apply() async {
        message = "正在应用…"
        await onApply(settings)
        message = "已应用"
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @Environment(\.dismiss) private var dismiss
    /// Offscreen rendering (`ImageRenderer`) draws a `ScrollView` as empty, which
    /// made the preview look like a broken page. In preview mode the sections go
    /// into a plain stack instead.
    var previewMode = false

    private var enabledCount: Int { model.settings.nodes.filter(\.enabled).count }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if previewMode {
                sections
            } else {
                ScrollView { sections }
            }
            Divider()
            footer
        }
        .frame(width: 600)
        .frame(height: previewMode ? nil : 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: 18) {
            machinesSection
            statusBarSection
            appearanceSection
            samplingSection
            powerSection
            generalSection
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 15))
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 1) {
                Text("SparkWatch 设置")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(model.settings.nodes.count) 台机器 · \(enabledCount) 台启用")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let message = model.message {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: - Machines

    private var machinesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("监控的机器")
            Spacer(minLength: 2)
            ForEach($model.settings.nodes) { $node in
                NodeEditor(model: model, node: $node)
            }
            .padding(.bottom, 4)
            Button {
                model.addNode()
            } label: {
                Label("添加机器", systemImage: "plus").font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: - Status bar

    private var statusBarSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("状态栏")
            VStack(alignment: .leading, spacing: 12) {
                LabeledRow("显示") {
                    Picker("", selection: $model.settings.statusBar.mode) {
                        ForEach(StatusBarSettings.Mode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 300)
                }
                // The element switches only exist for 自定义. Showing them for the
                // presets made the panel look like a cockpit while they did
                // nothing — the presets are the recommended answer, so they stay
                // out of the way until someone explicitly wants to hand-pick.
                if model.settings.statusBar.mode == .custom {
                    LabeledRow("可选元素", align: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 16) {
                                Toggle("节点名", isOn: $model.settings.statusBar.showNodeNames)
                                Toggle("GPU 利用率", isOn: $model.settings.statusBar.showUtilization)
                                Toggle("温度", isOn: $model.settings.statusBar.showTemperature)
                            }
                            HStack(spacing: 16) {
                                Toggle("内存占用", isOn: $model.settings.statusBar.showMemory)
                                Toggle("CPU 利用率", isOn: $model.settings.statusBar.showCPU)
                                Toggle("实时速度", isOn: $model.settings.statusBar.showSpeed)
                                Toggle("在线数", isOn: $model.settings.statusBar.showOnlineCount)
                            }
                            HStack(spacing: 16) {
                                Toggle("整机功耗估算", isOn: $model.settings.statusBar.showPower)
                                Toggle("整队状态点", isOn: $model.settings.statusBar.showFleetDot)
                                Toggle("只在异常时显示机名", isOn: $model.settings.statusBar.namesOnlyWhenRelevant)
                            }
                            Text("「整队状态点」= 一个点代表全队，颜色取最差的那台；关掉它、并关掉「只在异常时显示机名」时，每台机器都会单独列出自己的数字。")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                    }
                }
                LabeledRow("预览") {
                    HStack(spacing: 8) {
                        Text(model.statusBarPreview)
                            .font(.system(size: 12, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.07))
                            )
                        Text("（选“自定义”可逐项开关）")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground)
        }
    }

    // MARK: - Power

    private var powerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("功耗")
            VStack(alignment: .leading, spacing: 10) {
                LabeledRow("显示") {
                    HStack(spacing: 12) {
                        Toggle("显示整机预估功耗", isOn: $model.settings.powerEstimate.enabled)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 11))
                        Text("GPU 功耗是实测值（NVML）；整机是拟合值")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
                LabeledRow("拟合") {
                    HStack(spacing: 8) {
                        Text("整机 ≈")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        TextField("", value: $model.settings.powerEstimate.kGpu, format: .number.precision(.fractionLength(2)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 56)
                        Text("× GPU 轨 +")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        TextField("", value: $model.settings.powerEstimate.kCpu, format: .number.precision(.fractionLength(0)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 56)
                        Text("× CPU 满载比例")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        Button("恢复默认") {
                            model.settings.powerEstimate.kGpu = 1.61
                            model.settings.powerEstimate.kCpu = 95
                            model.settings.powerEstimate.floorW = 20
                            model.settings.powerEstimate.capW = 200
                            model.settings.powerEstimate.calibration = .report
                        }
                        .controlSize(.small)
                        Spacer()
                        Button("安装功率计后可自行校准") {}
                            .controlSize(.small)
                            .disabled(true)
                            .help("默认系数由公开的墙上功率计锚点约束拟合解出（2026 固件）：空载 GPU 11W→22–25W；MoE 解码 15W→45W；推理典型 35.7W→60–90W；双机 TP 对 47.7W→117W；CPU 满载 12W→120–130W；GPU 满载 87W→170W。锚点上最大残差 10.9W。")
                    }
                }
                LabeledRow("上下限") {
                    HStack(spacing: 8) {
                        TextField("", value: $model.settings.powerEstimate.floorW, format: .number.precision(.fractionLength(0)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 56)
                        Text("W 下限（当前固件空载 22–25W）·")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        TextField("", value: $model.settings.powerEstimate.capW, format: .number.precision(.fractionLength(0)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 56)
                        Text("W 上限（实测天花板 ~200W，240W 只是适配器额定）")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                LabeledRow("显示平滑") {
                    HStack(spacing: 8) {
                        TextField("", value: $model.settings.powerWindowSeconds,
                                  format: .number.precision(.fractionLength(0)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 56)
                        Text("秒窗口平均（0 = 显示瞬时值）")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        Button("恢复默认") { model.settings.powerWindowSeconds = 8 }
                            .controlSize(.small)
                        Spacer()
                    }
                    .help("TP 双机下原始功耗每 2–4 秒在 ~55W 与 ~84W 之间摆动（实测极差 34–41W），窗口短于这个周期只会共振；8 秒把相邻跳变从 9.4W 压到 1.7W。原始值始终可在卡片上悬停查看")
                }
                Text("GB10 无法自测整机功耗（板上没有电流监测芯片，DCGM 的 CPU/Module 功率字段恒为 0），所以这一项是按两个墙上功率计锚点拟合的：空闲 GPU 11.8W→整机 38W、生成时 GPU 47.7W→每台 117W，误差约 ±20%。注意它只看 GPU 轨：纯 CPU 负载（GPU 空转）会被低估。有功率计后请在此校准。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground)
        }
    }

    // MARK: - Appearance

    /// The four explicit palettes plus "follow the Mac". The swatches are drawn in
    /// *their own* colours, so the choice is made by looking at it rather than by
    /// reading its name — the same reason a code editor shows themes as thumbnails.
    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("外观")
            VStack(alignment: .leading, spacing: 10) {
                LabeledRow("主题") {
                    Picker("", selection: $model.settings.appearance) {
                        ForEach(AppTheme.allCases, id: \.self) { theme in
                            Text(theme.label).tag(theme)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 300)
                }
                LabeledRow("预览") {
                    HStack(spacing: 10) {
                        ForEach(AppTheme.allCases, id: \.self) { theme in
                            let preview = Palette.of(theme, dark: true)
                            HStack(spacing: 3) {
                                swatch(preview.base, preview.border)
                                swatch(preview.surface, preview.border)
                                swatch(preview.accent, preview.border)
                            }
                            .padding(2)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(
                                        model.settings.appearance == theme
                                            ? preview.accent : preview.border,
                                        lineWidth: model.settings.appearance == theme ? 2 : 1
                                    )
                            )
                            .help(theme.label)
                        }
                    }
                }
                Text("显式主题下 popover 与窗口自己刷底色，不用系统材质；「跟随系统」才用原生材质，随 Mac 的浅深色切换。")
                    .font(.system(size: 10.5, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func swatch(_ color: Color, _ border: Color) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(color)
            .frame(width: 12, height: 16)
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(border, lineWidth: 0.5))
    }

    // MARK: - Sampling

    /// The cadence knobs. Exposed because "how often does this thing look" is one of
    /// the three things that decide what a monitor can and cannot see (the other two
    /// being what it reads and how it presents it) — it was previously only editable
    /// by hand in the JSON.
    private var samplingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("采集")
            VStack(alignment: .leading, spacing: 10) {
                LabeledRow("硬件采样") {
                    HStack(spacing: 8) {
                        Stepper(
                            value: $model.settings.sampleIntervalSeconds,
                            in: 1...10,
                            step: 1
                        ) {
                            Text(String(format: "%.0f 秒", model.settings.sampleIntervalSeconds))
                                .font(.system(size: 11, design: .monospaced))
                        }
                        .frame(width: 130)
                    }
                }
                LabeledRow("慢探针") {
                    HStack(spacing: 8) {
                        Stepper(
                            value: $model.settings.slowProbeIntervalSeconds,
                            in: 5...300,
                            step: 5
                        ) {
                            Text(String(format: "%.0f 秒", model.settings.slowProbeIntervalSeconds))
                                .font(.system(size: 11, design: .monospaced))
                        }
                        .frame(width: 130)
                    }
                }
                Text("""
                硬件走官方遥测通道（约 1 Hz 推送，我们按上面的间隔采样）；慢探针是一次 SSH 往返，带磁盘、网络、容器、内核计数与 tailnet。
                推理探测不跟这个间隔：引擎在忙时 2 秒、空闲时 6 秒 —— 闲时计数器不动，探了也是白探。
                调快会让数字更及时，也会让被监控的机器多干活；默认 2 秒 / 60 秒是实测下来「看得出变化」与「不打扰机器」的平衡点。
                """)
                    .font(.system(size: 10.5, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - General

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("通用")
            VStack(alignment: .leading, spacing: 10) {
                LabeledRow("启动") {
                    HStack(spacing: 14) {
                        Toggle("开机自动启动", isOn: Binding(
                            get: { LoginItem.isEnabled },
                            set: { enabled in
                                if let problem = LoginItem.setEnabled(enabled) {
                                    model.message = "开机自启设置失败：\(problem)"
                                } else {
                                    model.message = enabled ? "已设为开机自启" : "已取消开机自启"
                                }
                                model.objectWillChange.send()
                            }
                        ))
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                        Button("立即启动一次") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: AppInfo.bundlePath))
                        }
                        .controlSize(.small)
                    }
                }
                LabeledRow("运行") {
                    HStack(spacing: 14) {
                        Toggle("暂停监控", isOn: Binding(
                            get: { model.pausedLocal },
                            set: { paused in
                                model.pausedLocal = paused
                                Task { await model.setPausedFromSettings(paused) }
                            }
                        ))
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                        Text("暂停后状态栏显示「⏸ 已暂停」，不再采集任何数据")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
                LabeledRow("版本") {
                    HStack(spacing: 8) {
                        Text("SparkWatch \(AppInfo.version) (\(AppInfo.build))")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Button("打开配置目录") {
                            NSWorkspace.shared.open(SettingsStore.directory)
                        }
                        .controlSize(.small)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text("需要 SSH 免密登录；DGX 机器另填系统账号用于面板登录（密码不落盘）。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button("关闭") { dismiss() }
            Button("保存并应用") {
                Task { await model.apply() }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.8)
            )
    }
}

// MARK: - Building blocks

private struct SectionTitle: View {
    var text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}

/// Label on the left, control on the right — one vertical axis for the page.
private struct LabeledRow<Content: View>: View {
    var label: String
    var align: VerticalAlignment = .firstTextBaseline
    @ViewBuilder var content: Content

    init(
        _ label: String,
        align: VerticalAlignment = .firstTextBaseline,
        @ViewBuilder content: () -> Content
    ) {
        self.label = label
        self.align = align
        self.content = content()
    }

    var body: some View {
        HStack(alignment: align, spacing: 10) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .trailing)
            content
        }
    }
}

private struct NodeEditor: View {
    @ObservedObject var model: SettingsModel
    @Binding var node: NodeConfig

    private var statusColor: Color {
        if !node.enabled { return .secondary }
        return node.sshHost.isEmpty ? .orange : .green
    }

    /// Services the last scan found on this machine.
    private var candidates: [InferenceCandidate] {
        model.previewNodes.first { $0.id == node.id }?.inferenceCandidates ?? []
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Status stripe: "enabled and configured" at a glance.
            RoundedRectangle(cornerRadius: 2)
                .fill(statusColor.opacity(0.8))
                .frame(width: 3)
                .padding(.vertical, 10)
                .padding(.trailing, 10)

            VStack(alignment: .leading, spacing: 10) {
                // Every row goes through LabeledRow, including the first, so all
                // fields share one vertical axis (the delete button sits outside
                // the grid, top-right, where it cannot break the alignment).
                // The scan proposes, the user decides: every service found on
                // this machine is offered here, plus "自动" (topology/scan) and
                // "不显示". A port scan cannot tell an idle leftover from a live
                // endpoint — that judgement belongs to the person watching.
                LabeledRow("推理服务") {
                    HStack(spacing: 8) {
                        Picker("", selection: $node.inferenceSource) {
                            Text("自动").tag(InferenceSource.auto)
                            if !candidates.isEmpty {
                                Divider()
                                ForEach(candidates) { candidate in
                                    Text(candidate.label)
                                        .tag(InferenceSource.pinned(
                                            candidate.url(forHost: node.sshHost)
                                        ))
                                }
                            }
                            Divider()
                            Text("不显示").tag(InferenceSource.hidden)
                        }
                        .labelsHidden()
                        .frame(width: 240)
                        Text(candidates.isEmpty
                             ? "尚未扫到服务（开始监控后自动填充）"
                             : "自动 = 集群拓扑优先，其次用扫描结果")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                LabeledRow("名称") {
                    HStack(spacing: 8) {
                        Toggle("", isOn: $node.enabled)
                            .labelsHidden()
                            .controlSize(.mini)
                            .help(node.enabled ? "已启用监控" : "已停用")
                        TextField("名称", text: $node.name)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 110)
                        TextField("SSH 主机 / IP", text: $node.sshHost)
                            .textFieldStyle(.roundedBorder)
                        TextField("用户", text: $node.sshUser)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                    }
                }

                LabeledRow("推理端点") {
                    HStack(spacing: 6) {
                        TextField(
                            "http://host:port（留空 = 只监控硬件）",
                            text: Binding(
                                get: { node.inferenceMetricsURL ?? "" },
                                set: { node.inferenceMetricsURL = $0.isEmpty ? nil : $0 }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        Button("扫描") { Task { await model.scan(node) } }
                            .controlSize(.small)
                            .disabled(node.sshHost.isEmpty || model.busy == node.id)
                        Button("体检") { Task { await model.check(node) } }
                            .controlSize(.small)
                            .disabled(node.sshHost.isEmpty || model.busy == node.id)
                    }
                }

                LabeledRow("面板转发") {
                    HStack(spacing: 6) {
                        TextField("", value: $node.dashboardLocalPort, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 64)
                        Text("本机端口，每台不同")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Toggle("自动发现端点", isOn: $node.autoDiscover)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 10))
                            .help("未配置时自动找；配置的端点连续失效时自动重找并切换")
                        SecureField(
                            "系统密码（仅用于面板登录）",
                            text: Binding(
                                get: { model.passwords[node.id] ?? "" },
                                set: { model.passwords[node.id] = $0 }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                    }
                }

                if model.busy == node.id {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("正在探测…").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }

                if let hits = model.scans[node.id], !hits.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("扫描结果 · 点一下填入")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        ForEach(hits, id: \.port) { hit in
                            Button {
                                node.inferenceMetricsURL = "http://\(node.sshHost):\(hit.port)"
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "bolt.horizontal").font(.system(size: 9))
                                    Text(":\(hit.port)").font(.system(size: 10, design: .monospaced))
                                    Text(hit.engine ?? "未知引擎").font(.system(size: 10))
                                    if let hitModel = hit.model {
                                        Text(hitModel)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))
                }

                if let results = model.checks[node.id] {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(results, id: \.name) { result in
                            HStack(alignment: .top, spacing: 5) {
                                Image(systemName: result.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(result.ok ? .green : .red)
                                Text(result.name)
                                    .font(.system(size: 10, weight: .medium))
                                    .frame(width: 86, alignment: .leading)
                                Text(result.detail)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))
                }
            }
            .padding(.vertical, 10)
            .padding(.trailing, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topTrailing) {
            Button {
                model.remove(node)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .help("删除这台机器")
            .padding(.top, 8)
            .padding(.trailing, 10)
        }
        .background(cardBackground)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.8)
            )
    }
}
