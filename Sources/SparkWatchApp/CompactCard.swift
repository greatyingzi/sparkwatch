import AppKit
import SparkWatchCore
import SwiftUI

/// The popover's compact tier: one machine, at a glance, in a fixed shape.
///
/// The rules this card exists to enforce (each one learned from a real
/// complaint, see the project README and the design notes):
///
///  1. **A fixed field set, so the height is known rather than hoped for.** The
///     rich card lives in the detail window, which can scroll and resize; a
///     popover cannot, and a data-dependent height is exactly what used to make
///     AppKit compress text into its neighbours.
///  2. **One ring, one number.** The ring holds GPU utilisation — the only
///     figure that moves every tick and that a glance actually has to read. The
///     temperature, the two power figures and the hottest thermal zone sit
///     beside it, outside the ring, because a ring with two values in it beats
///     neither a ring nor a bar.
///  3. **Only the numbers that change a decision.** Available memory used to
///     occupy a cell and was removed on request: on unified memory "6 GB
///     available" is the normal reading for a healthy box with a model resident.
///     Memory severity still reaches the card as a health chip, where the rules
///     judge it in absolute GB and PSI.
///  4. **Nothing the deployment banner already said.** When this machine is part
///     of a task, the banner above states the model, the rank and the
///     deployment-wide rate; repeating any of it here is what made this panel
///     read as 多又乱.
struct CompactCard: View {
    var snapshot: NodeSnapshot
    /// True when the deployment banner already names this machine's model and
    /// role, so the card must not say it again.
    var coveredByTask: Bool = false
    /// The wall-draw fit. GB10 cannot measure its own whole-machine power, so the
    /// number is a model — which is why it is labelled with ≈ and never coloured
    /// like the measured values beside it.
    var powerEstimate = PowerEstimate()
    /// Power display smoothing window in seconds (0 = raw). Only used for the
    /// tooltip — the value arrives already smoothed from the collector.
    var powerWindowSeconds: Double = 8
    /// Which service this card is showing, and how to change it.
    var inferenceSource: InferenceSource = .auto
    var onChooseSource: (InferenceSource) -> Void = { _ in }
    var onExpand: () -> Void
    var onLogin: () -> Void = {}
    /// Shut this machine down. Optional so the card still renders where no action
    /// context exists (previews, the compare window). The gate itself lives in
    /// `ShutdownSheet`, not here — one implementation of a dangerous flow.
    var onShutdown: (() -> Void)?
    var palette: Palette = .dark
    /// Recent decode rates for the speed sparkline, oldest first. Empty is fine —
    /// the sparkline then simply does not draw.
    var trends: [Double] = []

    static var height: CGFloat { Theme.cardHeight }

    private var isLive: Bool { snapshot.source != .down && !snapshot.connecting }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            head
            if snapshot.connecting {
                centred { connectingBody }
            } else if !isLive && snapshot.gpu.utilPct == nil {
                centred { offlineBody }
            } else {
                ringRow
                memoryRow
                if showsModelRow { modelRow }
                statLine
                if let reason = healthReason { healthChip(reason) }
                Spacer(minLength: 0)
                actions
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: Self.height, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(palette.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(cardBorder, lineWidth: 0.8)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onExpand() }
    }

    /// A card that is merely busy must not wear an alarm colour, so the border
    /// only lights up when a health rule fires.
    private var cardBorder: Color {
        switch snapshot.health.level {
        case .critical: palette.danger.opacity(0.5)
        case .warning: palette.warn.opacity(0.4)
        default: palette.cardBorder
        }
    }

    @ViewBuilder
    private func centred<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack {
            Spacer(minLength: 0)
            content()
            Spacer(minLength: 0)
        }
    }

    // MARK: - Head

    private var head: some View {
        HStack(spacing: 6) {
            StatusDot(level: snapshot.health.level, palette: palette)
            Text(snapshot.name)
                .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .truncationMode(.middle)
            if snapshot.connecting {
                Chip(text: "连接中", tint: palette.info)
            } else if snapshot.source == .down {
                Chip(text: "离线", tint: palette.danger)
            } else {
                Chip(text: snapshot.source.label, tint: sourceTint)
                if let role = snapshot.inference?.taskRole {
                    Chip(text: role, tint: palette.accent)
                } else if snapshot.health.level != .ok {
                    Chip(text: Theme.levelLabel(snapshot.health.level),
                         tint: palette.accent(for: snapshot.health.level))
                }
                // The one degraded state whose cause cannot be read off the numbers:
                // the SSH fallback keeps every figure plausible, so without this chip
                // (and the button in `actions`) a node whose official channel is
                // waiting for a password looks exactly like a healthy one.
                if snapshot.awaitingCredentials {
                    Chip(text: "需登录", tint: palette.warn)
                }
            }
            Spacer(minLength: 4)
            Text(snapshot.host)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    private var sourceTint: Color {
        switch snapshot.source {
        case .dashboard: palette.info
        case .sshFallback: palette.warn
        case .down: palette.danger
        }
    }

    // MARK: - Ring row

    private var ringRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Ring(
                value: snapshot.gpu.utilPct,
                size: 88,
                stroke: 8,
                tint: palette.utilization(snapshot.gpu.utilPct, tempC: snapshot.gpu.tempC),
                help: "GPU 利用率（官方遥测通道，约 1 Hz）"
            )
            VStack(spacing: 5) {
                HStack(spacing: 4) {
                    KVBox(
                        key: "温度",
                        value: snapshot.gpu.tempC.map { String(format: "%.0f", $0) } ?? "--",
                        unit: "°C",
                        tint: palette.temperature(snapshot.gpu.tempC),
                        help: "GPU 结温。85 °C 起注意、90 °C 起异常（GB10 自己不上报上限）"
                    )
                    KVBox(
                        key: "GPU 功耗",
                        value: snapshot.gpu.powerW.map { String(format: "%.1f", $0) } ?? "--",
                        unit: "W",
                        tint: .secondary,
                        help: powerHelp
                    )
                    KVBox(
                        key: "整机 ≈",
                        value: (snapshot.power?.wallW
                            ?? powerEstimate.wholeMachineW(gpuW: snapshot.gpu.powerW))
                            .map { String(format: "%.0f", $0) } ?? "--",
                        unit: "W",
                        tint: snapshot.power?.confidence == .low ? palette.warn : .secondary,
                        help: wholePowerHelp
                    )
                }
                HStack(spacing: 4) {
                    KVBox(
                        key: "最热区",
                        value: snapshot.system.cpuTempC.map { String(format: "%.0f", $0) } ?? "--",
                        unit: "°C",
                        tint: palette.temperature(snapshot.system.cpuTempC),
                        help: thermalHelp
                    )
                    KVBox(
                        key: "SM 时钟",
                        value: snapshot.gpu.smClockMHz.map { String(format: "%.2f", $0 / 1000) } ?? "--",
                        unit: "GHz",
                        tint: .secondary,
                        help: "SM 当前时钟。利用率高但时钟塌到 ≤800 MHz 且功耗低，才是真的降频"
                    )
                }
            }
        }
    }

    private var thermalHelp: String {
        guard let zone = snapshot.system.cpuTempC else { return "最热 ACPI 热区（GB10 没有 CPU 封装温度传感器）" }
        let limit = snapshot.system.thermalLimitC
        let base = "最热 ACPI 热区，不是 CPU 封装温度（GB10 没有那个传感器）"
        guard let limit else { return base }
        return base + String(format: "\n平台上限 %.0f °C，当前距上限 %.0f °C", limit, limit - zone)
    }

    // MARK: - Memory

    private var memoryRow: some View {
        let split = snapshot.system.memorySplit()
        var segments: [SegBar.Segment] = []
        if let gpu = split.gpu {
            segments.append(.init(
                label: "模型+KV", value: Double(gpu),
                color: palette.memEngine, text: gib(gpu), unit: ""
            ))
        }
        if let system = split.system {
            segments.append(.init(
                label: "系统", value: Double(system),
                color: palette.memSystem, text: gib(system), unit: ""
            ))
        }
        if let free = split.free {
            segments.append(.init(
                label: "空闲", value: Double(free),
                color: palette.surfaceHover, text: gib(free), unit: ""
            ))
        }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("统一内存")
                    .font(.system(size: 10.5, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(memoryCaption)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
            .help(memoryHelp)
            // A stacked bar answers "who took it", which a single-colour
            // occupancy bar cannot: on a unified pool "112 of 122 GiB used" is the
            // normal reading for a healthy box, and it is the split that turns it
            // into a decision. The GPU share is summed from the live compute-apps
            // (nvidia-smi's own memory.used is [N/A] on GB10); when that is
            // unavailable the bar degrades to 系统/空闲 rather than inventing a
            // weight figure.
            SegBar(segments: segments, height: 10, compact: true)
        }
    }

    private func gib(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1_073_741_824)
    }

    private var memoryCaption: String {
        let used = snapshot.gpu.memUsedBytes.map { Double($0) / 1_073_741_824 }
        let total = snapshot.gpu.memTotalBytes.map { Double($0) / 1_073_741_824 }
        guard let used, let total else { return "--" }
        return String(format: "%.1f / %.1f GiB", used, total)
    }

    /// The bar is a percentage; what decides anything on unified memory is the
    /// absolute headroom and whether anything is *waiting* on memory (PSI), so
    /// both are in the tooltip rather than on the card.
    private var memoryHelp: String {
        var parts: [String] = []
        if let pct = snapshot.gpu.memUsedPct {
            parts.append(String(format: "占用 %.0f%%（与 GPU 共享同一池）", pct))
        }
        if let available = snapshot.system.memAvailableBytes {
            parts.append(String(format: "可用 %.1f GiB", Double(available) / 1_073_741_824))
        }
        if let cache = snapshot.system.memCacheBytes {
            parts.append(String(format: "页缓存 %.1f GiB", Double(cache) / 1_073_741_824))
        }
        if let psi = snapshot.system.memPressureAvg10, psi > 0.01 {
            parts.append(String(format: "PSI 压力 %.2f（有东西在等内存）", psi))
        } else {
            parts.append("PSI 压力 0.00（没有任何东西在等内存）")
        }
        if let limit = snapshot.system.thermalLimitC, let zone = snapshot.system.cpuTempC {
            parts.append(String(format: "热区 %.0f / 上限 %.0f °C", zone, limit))
        }
        return parts.joined(separator: "\n")
    }

    // MARK: - Model

    /// A machine that is part of a task has its model and role stated once, in
    /// the banner. A standalone machine has no banner to say it, so it gets a row.
    private var showsModelRow: Bool {
        isLive && !coveredByTask
    }

    private var modelRow: some View {
        HStack(spacing: 6) {
            Text(inferenceText)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isProbingInference ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            if let quant = snapshot.inference?.quantization {
                Chip(text: quant.uppercased(), tint: palette.violet, compact: true)
            }
            if let ctx = snapshot.inference?.contextLength, ctx > 0 {
                Chip(text: ctx >= 1024 ? "\(ctx / 1024)K" : "\(ctx)", tint: .secondary, compact: true)
                    .help("上下文窗口 \(ctx) tokens")
            }
            Spacer(minLength: 4)
            speedBadge
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(palette.accentSoft)
        )
        .help(inferenceHelp)
    }

    private var isProbingInference: Bool {
        snapshot.inference == nil && snapshot.inferenceConfigured && snapshot.source != .down
    }

    private var inferenceText: String {
        guard let inference = snapshot.inference else {
            if snapshot.inferenceConfigured { return "正在探测推理端点…" }
            return snapshot.source == .sshFallback ? "未发现推理服务" : "未配置推理端点"
        }
        return inference.model ?? "无模型加载"
    }

    private var inferenceHelp: String {
        guard let inference = snapshot.inference else {
            return snapshot.inferenceError ?? "尚未拿到推理端点的应答"
        }
        var parts: [String] = []
        if let engine = inference.engine { parts.append("引擎 \(engine)") }
        if let endpoint = inference.endpoint { parts.append(endpoint) }
        if let note = snapshot.inferenceNote { parts.append(note) }
        if let error = snapshot.inferenceError { parts.append("错误：\(error)") }
        return parts.joined(separator: "\n")
    }

    /// Live speed is green; a rate whose counter stopped goes grey with its age,
    /// so nothing bright stays on screen claiming to be current.
    @ViewBuilder
    private var speedBadge: some View {
        if let inference = snapshot.inference, let tps = inference.decodeTPS, tps > 0.5 {
            let state = SpeedDisplay.state(
                rate: tps, age: inference.decodeTPSAge, running: inference.running
            )
            if state != .hidden {
                HStack(spacing: 3) {
                    Text(SpeedDisplay.text(rate: tps, age: inference.decodeTPSAge, stopped: state == .stopped))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(state == .live ? palette.ok : Color.secondary)
                        // 速度这一对（数字 + 单位）在窄卡片里也要保持一行。
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .fixedSize(horizontal: true, vertical: false)
                    Sparkline(values: trends, tint: state == .live ? palette.ok : .secondary)
                        .frame(width: 46, height: 14)
                        .opacity(state == .live ? 1 : 0.6)
                }
                .help(state == .live ? "实时解码速度（计数器差值）" : "已停止：显示最后一次测到的速度与它的年龄")
            }
        } else if snapshot.inference?.capabilities.hasSpeed == true {
            Text("空闲")
                .font(.system(size: 10.5, design: .rounded))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Stats line

    /// The engine counters, one line. These are the numbers that explain *why*
    /// the ring says what it says, and they belong on the popover because they
    /// change what you would do next (queue full → requests will wait).
    private var statLine: some View {
        var items: [StatLine.Item] = []
        if let inference = snapshot.inference {
            if let kv = inference.kvUsagePct {
                items.append(.init(key: "KV", value: String(format: "%.0f%%", kv),
                                   tint: palette.kv(kv)))
            }
            if let running = inference.running {
                let waiting = inference.waiting ?? 0
                items.append(.init(key: "run", value: String(format: "%.0f/%.0f", running, waiting),
                                   tint: waiting > 0 ? palette.warn : .secondary))
            }
            if let acceptance = inference.acceptancePct {
                items.append(.init(key: "MTP", value: String(format: "%.0f%%", acceptance), tint: .secondary))
            }
            if let hit = inference.cacheHitPct {
                items.append(.init(key: "命中", value: String(format: "%.0f%%", hit), tint: .secondary))
            }
            if let oldest = inference.oldestSeconds, oldest >= 1 {
                items.append(.init(key: "最老", value: String(format: "%.0fs", oldest), tint: .secondary))
            }
        }
        if items.isEmpty, snapshot.health.reasons.isEmpty {
            items.append(.init(key: "负载", value: String(format: "%.2f", snapshot.system.load1 ?? 0),
                               tint: .secondary))
        }
        return StatLine(
            items: items,
            trailing: trailingStats
        )
    }

    private var trailingStats: String? {
        var parts: [String] = []
        if let cpu = snapshot.system.cpuUsagePct { parts.append(String(format: "CPU %.0f%%", cpu)) }
        if let load = snapshot.system.load1 { parts.append(String(format: "load %.2f", load)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func healthChip(_ reason: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 8.5))
            Text(reason)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .foregroundStyle(palette.accent(for: snapshot.health.level))
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(palette.accent(for: snapshot.health.level).opacity(0.12))
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(palette.accent(for: snapshot.health.level))
                .frame(width: 3)
        }
        .help(snapshot.health.reasons.joined(separator: "\n"))
    }

    private var healthReason: String? {
        snapshot.health.reasons.first
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: 6) {
            Button(action: onExpand) {
                Label("详情", systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.accentText)
            .help("在详情窗口打开 \(snapshot.name)")

            SourceMenu(snapshot: snapshot, source: inferenceSource, onChoose: onChooseSource, palette: palette)

            Spacer(minLength: 0)
            // The fix, one click from the state that needs it: the card already
            // says 需登录 in its head, and a state that requires an action should
            // carry the action rather than sending the user off to the settings
            // window to find it.
            if snapshot.awaitingCredentials, !snapshot.connecting {
                Button(action: onLogin) {
                    Text("登录")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(palette.accentText)
                }
                .buttonStyle(.plain)
                .help("输入系统账号密码，恢复官方遥测通道")
            }
            if let onShutdown, isLive {
                Button(action: onShutdown) {
                    Text("关机")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(palette.danger)
                }
                .buttonStyle(.plain)
                .help("优雅关机（需要输入 poweroff 确认）")
            } else if !snapshot.system.containers.isEmpty {
                Text(snapshot.system.containers.prefix(2).map(\.name).joined(separator: " · "))
                    .font(.system(size: 9.5, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.top, 1)
    }

    // MARK: - Degraded bodies

    private var connectingBody: some View {
        HStack(spacing: 9) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("正在连接…")
                    .font(.system(size: 11.5, design: .rounded))
                    .foregroundStyle(.secondary)
                Text("建立 SSH 隧道 → 登录面板 → 订阅遥测")
                    .font(.system(size: 9.5, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
    }

    private var offlineBody: some View {
        HStack(spacing: 9) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.error ?? "无响应")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text("SSH 不通 / 面板未就绪")
                    .font(.system(size: 9.5, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Button("登录") { onLogin() }
                .controlSize(.small)
        }
    }

    // MARK: - Helpers

    /// The power figures are windowed means (see TimeWindowMean): on a TP pair
    /// the raw reading swings tens of watts every couple of seconds, so a stable
    /// number is the only readable one — and the raw sample stays one hover away,
    /// because a smoothed figure nobody can check is just a nicer-looking lie.
    /// What the `≈W` cell actually is: one shared model, with its inputs spelled
    /// out. A smoothed number that cannot be checked is a prettier lie.
    private var wholePowerHelp: String {
        guard let reading = snapshot.power else {
            return "按 GPU 轨拟合的估值，不是实测（GB10 没有整机功率计）"
        }
        var text = powerEstimate.formula(for: reading) + "\n"
        text += reading.cpuAssumed
            ? "CPU 占用未读到，按 20% 估。\n"
            : "输入：GPU 轨实测 + CPU 占用（按频率加权）。\n"
        if let note = reading.note { text += "低置信：\(note)\n" }
        text += "口径：2026 固件公开墙端锚点约束拟合（空载 22–25W / 解码 45W / 推理 60–90W / 双机 TP 117W / CPU 满载 120–130W / GPU 满载 170W），锚点最大残差 10.9W。"
        return text
    }

    private var powerHelp: String {
        guard let mean = snapshot.gpu.powerW else { return "GPU 轨实测功耗（NVML power.draw）" }
        let window = powerWindowSeconds > 0
            ? String(format: "%.0f 秒窗口平均", powerWindowSeconds) : "瞬时值"
        guard let instant = snapshot.gpu.powerInstantW else {
            return String(format: "GPU 轨实测：%@ %.1f W\nGB10 只量 GPU 侧，没有整机功率计", window, mean)
        }
        return String(
            format: "GPU 轨实测：%@ %.1f W（瞬时 %.1f W）\nGB10 只量 GPU 侧，没有整机功率计",
            window, mean, instant
        )
    }
}

/// The scan proposes, the user decides. A port scan cannot tell an idle leftover
/// from a live endpoint, so every service found on the machine is offered
/// alongside 自动 and 不显示.
struct SourceMenu: View {
    var snapshot: NodeSnapshot
    var source: InferenceSource
    var onChoose: (InferenceSource) -> Void
    var palette: Palette

    var body: some View {
        Menu {
            Picker("", selection: Binding(get: { source }, set: { onChoose($0) })) {
                Text("自动").tag(InferenceSource.auto)
                if !snapshot.inferenceCandidates.isEmpty {
                    Divider()
                    ForEach(snapshot.inferenceCandidates) { candidate in
                        Text(candidate.label)
                            .tag(InferenceSource.pinned(candidate.url(forHost: snapshot.host)))
                    }
                }
                Divider()
                Text("不显示").tag(InferenceSource.hidden)
            }
            .pickerStyle(.inline)
        } label: {
            Text(label)
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(palette.accentText)
        .help("选择这一台显示的推理服务（可手动指定扫描到的服务）")
    }

    private var label: String {
        switch source {
        case .auto: "来源 ▾"
        case let .pinned(url):
            url.split(separator: ":").last.map { ":\($0) ▾" } ?? "固定 ▾"
        case .hidden: "已隐藏 ▾"
        }
    }
}
