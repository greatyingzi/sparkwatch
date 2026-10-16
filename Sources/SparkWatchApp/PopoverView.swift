import AppKit
import SparkWatchCore
import SwiftUI

// The visual language (tokens, geometry, thresholds) lives in Theme.swift and
// the shared controls in Controls.swift — one place for it, so the status-bar
// chip, the popover, the detail window and the settings window cannot drift
// apart.

// MARK: - Small pieces

/// One distributed deployment, shown once above the per-machine cards.
///
/// Without this the two boxes read as two unrelated single-box servers, and a
/// headless rank looks like a machine with no model at all — when in fact the
/// pair is serving one model together, as the throughput of a single request
/// proves (both GPUs step to ~95 % at the same instant).
struct TaskBanner: View {
    var task: ClusterTask
    /// Deployment-wide numbers, shown once here instead of once per card: power is
    /// a property of the whole deployment, not of one box.
    var powerW: Double?
    /// The one live slot: decode rate, prefill rate, or in-flight count — the
    /// rate of whatever is actually happening right now.
    var activity: TaskActivity?
    /// Theme tokens (see `Palette`).
    var palette: Palette = .dark

    /// Colour per kind: green = producing tokens, blue = swallowing a prompt,
    /// grey = in flight but no measurable rate yet.
    private func tint(for kind: TaskActivity.Kind) -> Color {
        switch kind {
        case .decoding: palette.ok
        // Last known, not now: grey says "this happened a moment ago" without
        // pretending it is live.
        case .decodingStale: .secondary
        case .prefilling: palette.info
        case .busy: .secondary
        }
    }

    /// "spark-00" -> "00"
    private func short(_ node: String) -> String {
        node.replacingOccurrences(of: "spark-", with: "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Row 1 answers "what is this": the model and its shape. The chips on
            // this row are fixed-width facts, so the name gets the room it needs
            // and does not truncate into "GLM-5…4bpw".
            HStack(spacing: 6) {
                Image(systemName: task.isParallel ? "square.stack.3d.up.fill" : "square.stack.3d.up")
                    .font(.system(size: 10))
                    .foregroundStyle(
                        task.isParallel ? AnyShapeStyle(palette.info) : AnyShapeStyle(.secondary)
                    )
                Text(task.model)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(task.model)
                Chip(text: task.topologyLabel, tint: task.isParallel ? palette.info : .secondary)
                if let drafter = task.drafter { Chip(text: drafter, tint: palette.violet) }
                if let quant = task.quantization { Chip(text: quant.uppercased(), tint: palette.violet) }
                if let ctx = task.contextLength {
                    // Just the number: "ctx" costs 25 pt on a 400 pt row, and that
                    // is 25 pt the model name needs (it was truncating to
                    // "GLM-5.3-F…h-tr3-4bpw"). The tooltip spells it out.
                    Chip(text: ctx >= 1024 ? "\(ctx / 1024)K" : "\(ctx)", tint: .secondary)
                        .help("上下文窗口 \(ctx) tokens")
                }
                Spacer(minLength: 0)
            }
            // Row 2 answers "what is it doing right now": who serves, and the three
            // live numbers. Putting the numbers here rather than on row 1 is what
            // keeps both rows readable at 400 pt.
            HStack(spacing: 6) {
                ForEach(task.nodes, id: \.self) { node in
                    HStack(spacing: 3) {
                        Text(short(node))
                            .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        Text(task.roleLabel(for: node))
                            .font(.system(size: 9, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
                Spacer(minLength: 4)
                if let activity {
                    // The live slot. Rendered before the watts so the eye lands on
                    // "what is it doing" first.
                    Text(activity.text)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(tint(for: activity.kind))
                        .lineLimit(1)
                        .help("引擎报告的实时状态：▶ 生成速度 · ⇡ 提示处理（prefill）速度 · ×N 并发请求数")
                }
                if let powerW {
                    Text(String(format: "≈%.0fW", powerW))
                        .font(.system(size: 10.5, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help("整机功耗是按 GPU 轨拟合的估算值（两个墙上功率计锚点解出），不是实测")
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(palette.accentSoft)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(palette.accent.opacity(0.28), lineWidth: 0.5)
        )
    }
}

struct CardHeightKey: PreferenceKey {
    static let defaultValue: [UUID: CGFloat] = [:]
    static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { max($0, $1) })
    }
}

struct NodeCard: View {
    var snapshot: NodeSnapshot
    var history: AppModel.History
    /// Power display smoothing window in seconds (0 = raw); tooltips only.
    var powerWindowSeconds: Double = 8
    /// Which service this card is showing, and how to change it.
    var inferenceSource: InferenceSource = .auto
    var onChooseSource: (InferenceSource) -> Void = { _ in }
    /// Only used for the whole-machine power estimate (GB10 cannot measure it).
    var powerEstimate = PowerEstimate()
    /// Theme tokens. Passed explicitly rather than read from the environment so
    /// the same card renders correctly in an offscreen preview (no window, no
    /// appearance) and in the real windows.
    var palette: Palette = .dark
    /// Shared card height (a minimum, applied where the background is drawn).
    var height: CGFloat = 240
    /// Whether the utilisation cell carries its own micro-trend sparkline.
    ///
    /// Off on the machine page, where `GpuHistoryChart` owns history: two graphics
    /// of the same quantity with different windows on one screen reads as a
    /// duplicate (and it was — reported by the user as 重复). The card's sparkline
    /// is a ~1 minute "is it ramping right now" cue, which is exactly what the chart
    /// cannot show at its 30-minute scale, so the split is: card = now, chart =
    /// history.
    var showsTrend = true
    var onLogin: () -> Void
    var onSignOut: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if snapshot.connecting {
                // Equal-height cards leave a sparse node with a lot of space;
                // centre the body so it reads as intentional, not top-heavy.
                VStack {
                    Spacer(minLength: 0)
                    connectingBody
                    Spacer(minLength: 0)
                }
            } else if snapshot.source == .down && snapshot.gpu.utilPct == nil {
                VStack {
                    Spacer(minLength: 0)
                    offlineBody
                    Spacer(minLength: 0)
                }
            } else {
                kpiStrip
                memoryRow
                statGrid
                ioRow
                // Centre the inference block so a card with no endpoint (or a
                // very short one) doesn't end up with all its slack at the
                // bottom, which reads as a rendering fault.
                VStack {
                    Spacer(minLength: 0)
                    inferenceRow
                    Spacer(minLength: 0)
                }
                if !snapshot.system.containers.isEmpty { containerRow }
                if !snapshot.health.reasons.isEmpty { healthRow }
            }
        }
        .padding(Theme.gutter - 2)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: CardHeightKey.self, value: [snapshot.id: proxy.size.height])
            }
        )
        .frame(maxWidth: .infinity, minHeight: height, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous).fill(palette.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(palette.cardBorder, lineWidth: 0.8)
        )
    }

    private var header: some View {
        HStack(spacing: 7) {
            StatusDot(level: snapshot.health.level, palette: palette)
            Text(snapshot.name)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
            // While the first sample is pending the chip must not claim the node
            // is down: "down" and "still connecting" are different states.
            if snapshot.connecting {
                Chip(text: "连接中", tint: .blue)
            } else {
                Chip(
                    text: snapshot.source.label,
                    tint: snapshot.source == .dashboard ? .blue
                        : (snapshot.source == .sshFallback ? .orange : .red)
                )
                if snapshot.source != .down, snapshot.health.level != .ok {
                    Chip(text: Theme.levelLabel(snapshot.health.level),
                         tint: palette.accent(for: snapshot.health.level))
                }
                // A green dot means "hardware healthy"; say so explicitly when
                // there is no inference endpoint, or green reads as "all good"
                // while a whole half of the card is empty.
                // A rank of a distributed task serves the task's model without
                // owning an endpoint; calling that "无推理端点" was misleading.
                if snapshot.inference?.taskRole != nil {
                    Chip(text: "集群 worker", tint: .teal)
                } else if !snapshot.inferenceConfigured, inferenceSource == .auto {
                    Chip(text: "无推理端点", tint: .secondary)
                }
                if snapshot.awaitingCredentials {
                    Chip(text: "需登录", tint: palette.warn)
                }
            }
            Spacer(minLength: 6)
            // The state's own cure, next to the state: the official channel is off
            // until someone signs in, and the numbers below look healthy meanwhile.
            if snapshot.awaitingCredentials, !snapshot.connecting {
                Button("登录") { onLogin() }
                    .controlSize(.small)
                    .help("输入系统账号密码，恢复官方遥测通道")
            }
            // Cores + uptime as context next to the host, so the metric grid can
            // spend its cells on live numbers.
            Text(headerContext)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    private var headerContext: String {
        var parts: [String] = [snapshot.host]
        if let cores = snapshot.system.cpuCores { parts.append("\(cores) 核") }
        if let uptime = snapshot.system.uptimeSeconds {
            parts.append(String(format: "%.1f 天", uptime / 86400))
        }
        return parts.joined(separator: " · ")
    }
    private var connectingBody: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("正在连接…")
                    .font(.system(size: 11.5, design: .rounded))
                    .foregroundStyle(.secondary)
                Text("建立 SSH 隧道 → 登录面板 → 订阅遥测")
                    .font(.system(size: 9.5, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var offlineBody: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 20))
                .symbolRenderingMode(.monochrome)
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
            Spacer()
            Button("登录") { onLogin() }
                .controlSize(.small)
        }
    }

    private var kpiStrip: some View {
        HStack(alignment: .bottom, spacing: 14) {
            Metric(
                title: "GPU 利用率",
                value: snapshot.gpu.utilPct.map { String(format: "%.0f", $0) } ?? "--",
                unit: "%",
                detail: nil,
                tint: palette.utilization(snapshot.gpu.utilPct, tempC: snapshot.gpu.tempC)
            )
            .frame(width: showsTrend ? 104 : nil, alignment: .leading)
            if showsTrend {
                // Stretches to the card's content edge — a half-width trend line
                // reads as a broken layout.
                Sparkline(
                    values: history.util,
                    tint: palette.utilization(snapshot.gpu.utilPct, tempC: snapshot.gpu.tempC),
                    fixedMax: 100
                )
                .frame(height: 34)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Every statistic in the card lives on this one four-column grid, so the
    /// labels and values share a single axis instead of drifting per row.
    /// The power figures are windowed means (see TimeWindowMean). The raw sample
    /// is always one hover away — a smoothed number nobody can check against the
    /// instant it came from is just a nicer-looking lie.
    private var powerHelp: String {
        guard let mean = snapshot.gpu.powerW else { return "" }
        let window = powerWindowSeconds > 0
            ? String(format: "%.0f 秒窗口平均", powerWindowSeconds) : "瞬时值"
        guard let instant = snapshot.gpu.powerInstantW else {
            return String(format: "%@ %.1f W", window, mean)
        }
        return String(format: "%@ %.1f W（瞬时 %.1f W）", window, mean, instant)
    }

    private var statGrid: some View {
        VStack(spacing: 9) {
            HStack(spacing: 0) {
                StatCell(key: "GPU 温度", value: snapshot.gpu.tempC.map { String(format: "%.0f°C", $0) } ?? "--")
                // NVML's power.draw on GB10 covers the GPU side of the SoC only:
                // no module/board power, no CPU/DRAM/NVMe/NIC, no PSU loss.
                StatCell(
                    key: "GPU 功耗",
                    value: snapshot.gpu.powerW.map { String(format: "%.1f W", $0) } ?? "--",
                    help: powerHelp
                )
                // Modelled, not measured — see PowerEstimate for the fit and why
                // no on-box whole-machine number exists on GB10.
                StatCell(
                    key: "整机≈功耗",
                    value: powerEstimate.wholeMachineW(gpuW: snapshot.gpu.powerW)
                        .map { String(format: "≈%.0f W", $0) } ?? "--"
                )
                // GB10 exposes no CPU package sensor; the honest number is the
                // hottest ACPI thermal zone (see README).
                StatCell(
                    key: "最热区",
                    value: snapshot.system.cpuTempC.map { String(format: "%.0f°C", $0) } ?? "--"
                )
            }
            HStack(spacing: 0) {
                StatCell(
                    key: "可用(含缓存)",
                    value: snapshot.system.memAvailableBytes.map {
                        String(format: "%.1f GiB", Double($0) / 1_073_741_824)
                    } ?? "--"
                )
                StatCell(
                    key: "缓存",
                    value: snapshot.system.memCacheBytes.map {
                        String(format: "%.1f GiB", Double($0) / 1_073_741_824)
                    } ?? "--"
                )
                StatCell(key: "CPU", value: snapshot.system.cpuUsagePct.map { String(format: "%.0f%%", $0) } ?? "--")
                StatCell(key: "负载", value: snapshot.system.load1.map { String(format: "%.2f", $0) } ?? "--")
            }
            HStack(spacing: 0) {
                StatCell(key: "磁盘", value: diskText)
                StatCell(
                    key: "PSI 压力",
                    value: snapshot.system.memPressureAvg10.map { String(format: "%.2f", $0) } ?? "--"
                )
                StatCell(
                    key: "swap",
                    value: snapshot.system.swapUsedBytes.flatMap { $0 > 100_000_000
                        ? String(format: "%.1f GiB", Double($0) / 1_073_741_824) : nil } ?? "—"
                )
                StatCell(
                    key: "运行",
                    value: snapshot.system.uptimeSeconds.map { String(format: "%.1f 天", $0 / 86400) } ?? "--"
                )
            }
        }
    }

    private var memoryRow: some View {
        let usedGiB = snapshot.gpu.memUsedBytes.map { Double($0) / 1_073_741_824 }
        let totalGiB = snapshot.gpu.memTotalBytes.map { Double($0) / 1_073_741_824 }
        let split = snapshot.system.memorySplit()
        var segments: [SegBar.Segment] = []
        if let gpu = split.gpu {
            segments.append(.init(label: "模型权重 + KV", value: Double(gpu),
                                  color: palette.memEngine, text: giB(gpu)))
        }
        if let system = split.system {
            segments.append(.init(label: "系统", value: Double(system),
                                  color: palette.memSystem, text: giB(system)))
        }
        if let free = split.free {
            segments.append(.init(label: "空闲", value: Double(free),
                                  color: palette.surfaceHover, text: giB(free)))
        }

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("统一内存")
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(snapshot.gpu.memUsedPct.map { String(format: "%.0f%%", $0) } ?? "--")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(palette.memory(snapshot.gpu.memUsedPct))
            }
            // Split by *who* holds the pool. A single-colour occupancy bar cannot
            // say this, and on a unified pool it is the only part that changes a
            // decision: "112 of 122 GiB used" is normal, "and 97 of those are the
            // model" is the explanation.
            SegBar(segments: segments, height: 10)
            Text(meterLabel(usedGiB: usedGiB, totalGiB: totalGiB))
                .font(.system(size: 9.5, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private func giB(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1_073_741_824)
    }

    /// The slow-channel facts that have no home in the KPI grid: what the machine
    /// is moving in and out, and whether it is still on its tailnet.
    private var ioRow: some View {
        let network = snapshot.system.network
        let primary = network.primaryInterface
        let disk = (snapshot.system.diskReadBytesPerSec, snapshot.system.diskWriteBytesPerSec)
        let kernel = snapshot.system.kernelErrors

        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 0) {
                StatCell(
                    key: "网络 ↓↑",
                    value: primary.map {
                        "\(Self.rate($0.rxBytesPerSec)) / \(Self.rate($0.txBytesPerSec))"
                    } ?? "--",
                    help: primary.map {
                        "\($0.name)"
                            + ($0.ip.map { " · \($0)" } ?? "")
                            + ($0.linkSpeedMbps.map { " · \(Int($0)) Mb/s" } ?? "")
                    } ?? "没有可读的物理网卡"
                )
                StatCell(
                    key: "磁盘 r/w",
                    value: disk.0 != nil || disk.1 != nil
                        ? "\(Self.rate(disk.0 ?? 0)) / \(Self.rate(disk.1 ?? 0))" : "--",
                    help: "根块设备读/写吞吐（两次 /sys/block 采样差分）"
                )
                StatCell(
                    key: "Tailnet",
                    value: snapshot.system.tailnet.map { $0.online ? $0.pathLabel : "离线" } ?? "--",
                    help: snapshot.system.tailnet.map {
                        "由该节点自报：\($0.online ? "在线" : "离线") · 路径 \($0.pathLabel)"
                            + ($0.ip.map { " · \($0)" } ?? "")
                            + ($0.keyExpired ? " · 密钥已过期，需要重新认证" : "")
                    } ?? "该节点读不到 tailscale 状态"
                )
                StatCell(
                    key: "内核事件",
                    value: kernel.available
                        ? (kernel.isClean ? "干净" : "\(kernel.xid)/\(kernel.oomKills)/\(kernel.nvErrNoMemory)")
                        : "不可读",
                    help: kernel.available
                        ? "开机以来 Xid / OOM-kill / 显存分配失败 次数。计数上升才会升级为异常"
                        : "读不到内核日志（没有 dmesg 权限、也没有 journal）"
                )
            }
            if snapshot.system.incidentActive {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9))
                    Text("内核事件上升：Xid \(kernel.xid) · OOM \(kernel.oomKills) · 显存分配失败 \(kernel.nvErrNoMemory)")
                        .font(.system(size: 10, design: .rounded))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(palette.danger)
            }
        }
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        let text: String =
            switch bytesPerSecond {
            case ..<1024: String(format: "%.0f B/s", bytesPerSecond)
            case ..<1_048_576: String(format: "%.0f KB/s", bytesPerSecond / 1024)
            case ..<1_073_741_824: String(format: "%.1f MB/s", bytesPerSecond / 1_048_576)
            default: String(format: "%.2f GB/s", bytesPerSecond / 1_073_741_824)
            }
        // 值 + 单位用不换行空格粘住：这类字符串会被拼进更长的行，普通空格会让
        // "12.3" 和 "KB/s" 在行尾被拆开（见 Rate.nbsp 的说明）。
        return text.replacingOccurrences(of: " ", with: Rate.nbsp)
    }

    private var diskText: String {
        guard let used = snapshot.system.diskUsedBytes, let total = snapshot.system.diskTotalBytes, total > 0
        else { return "--" }
        return String(format: "%.0f%%", Double(used) * 100 / Double(total))
    }

    /// Memory bar caption; PSI only appears when it is actually non-zero, which
    /// is the moment it means something.
    private func meterLabel(usedGiB: Double?, totalGiB: Double?) -> String {
        var label = usedGiB != nil && totalGiB != nil
            ? String(format: "%.1f / %.1f GiB", usedGiB!, totalGiB!) : "--"
        if let pressure = snapshot.system.memPressureAvg10, pressure > 0.01 {
            label += String(format: "  ·  PSI %.2f", pressure)
        }
        return label
    }

    @ViewBuilder
    private var inferenceRow: some View {
        Divider().opacity(0.4)
        if inferenceSource.isHidden {
            HStack(spacing: 6) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text("推理服务已隐藏")
                    .font(.system(size: 10.5, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                sourceMenu
            }
        } else if let inference = snapshot.inference {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "brain")
                        .font(.system(size: 9))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(.secondary)
                    // A model server with nothing loaded is a real state (Ollama
                    // unloads after idle); say so instead of printing "?".
                    Text(inference.model ?? "无模型加载")
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(inference.model == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    // A rank of a distributed task reports its role, not a
                    // stale local engine: rank 1's Ollama has nothing to do
                    // with what this box is serving.
                    if let role = inference.taskRole {
                        Chip(text: role, tint: .teal)
                    } else if let engine = inference.engine {
                        Chip(text: engine, tint: .purple)
                    }
                    // Model facts, when the engine exposes them.
                    if let quant = inference.quantization { Chip(text: quant, tint: .indigo) }
                    if let ctx = inference.contextLength {
                        Chip(text: ctx >= 1024 ? "\(ctx / 1024)K ctx" : "\(ctx) ctx", tint: .gray)
                    }
                    Spacer(minLength: 4)
                    speedBadge(inference)
                    sourceMenu
                }
                if let note = snapshot.inferenceNote {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkle")
                            .font(.system(size: 9))
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(.tertiary)
                        Text(note)
                            .font(.system(size: 9.5, design: .rounded))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                // Only show counters the engine actually has; three "--" columns
                // look like a broken card rather than an engine limitation.
                if inference.engine == "cluster" {
                    // A rank of a distributed deployment owns no endpoint of its
                    // own — its numbers are the deployment's, and those are
                    // stated once in the banner. Saying "this engine provides no
                    // counters" here would describe a service this box is not
                    // running at all.
                    HStack(spacing: 5) {
                        Image(systemName: "square.stack.3d.up.fill")
                            .font(.system(size: 9))
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(.teal)
                        Text("本机是集群 rank：无自有端点，速率与请求数以 API 端为准")
                            .font(.system(size: 9.5, design: .rounded))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                } else if inference.capabilities.hasRequestCounters || inference.capabilities.hasTokenCounters {
                    HStack(alignment: .top, spacing: 12) {
                        if inference.capabilities.hasRequestCounters {
                            StatCell(key: "run", value: inference.running.map { String(format: "%.0f", $0) } ?? "--")
                            StatCell(key: "wait", value: inference.waiting.map { String(format: "%.0f", $0) } ?? "--")
                        }
                        if inference.capabilities.hasTokenCounters {
                            StatCell(
                                key: "累计生成",
                                value: inference.generationTokens.map { formatTokens($0) } ?? "--"
                            )
                            StatCell(
                                key: "请求数",
                                value: inference.requestsProcessed.map { formatTokens($0) } ?? "--"
                            )
                        }
                        if let vram = inference.vramBytes {
                            StatCell(key: "显存", value: String(format: "%.1f GiB", Double(vram) / 1_073_741_824))
                        }
                        if let kv = inference.kvUsagePct {
                            StatCell(key: "KV", value: String(format: "%.0f%%", kv))
                        }
                        if let acceptance = inference.acceptancePct {
                            StatCell(key: "投机接受", value: String(format: "%.0f%%", acceptance))
                        }
                        // Prefix-cache hit rate: on agentic traffic this is why a
                        // 300K-token prompt costs nothing to prefill.
                        if let hit = inference.cacheHitPct {
                            StatCell(key: "缓存命中", value: String(format: "%.0f%%", hit))
                        }
                        // Prompt-processing speed, as the engine accounts for it:
                        // newly computed prompt tokens (prompt − cached) per second
                        // of prefill work, for the requests that finished since the
                        // last sample. Not a live readout — the engine only
                        // updates these counters when a request completes.
                        if let prefill = inference.prefillTPS, prefill > 0.5 {
                            StatCell(key: "prefill", value: "\(TaskSummary.formatRate(prefill))/s")
                                .help("最近完成请求的实测 prefill 速度（引擎自报：已计算 prompt token ÷ prefill 秒数，不含缓存命中部分）；prefill 进行中的实时进度看 ×N 与秒数")
                        }
                    }
                } else {
                    HStack(spacing: 5) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 9))
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(.tertiary)
                        Text(
                            inference.vramBytes.map {
                                String(format: "该引擎不提供速率/请求计数 (显存 %.1f GiB)", Double($0) / 1_073_741_824)
                            } ?? "该引擎不提供速率/请求计数"
                        )
                        .font(.system(size: 9.5, design: .rounded))
                        .foregroundStyle(.tertiary)
                        Spacer()
                    }
                }
            }
        } else {
            // Three distinct states, three different messages: nothing
            // configured, configured but not answered yet, and configured plus
            // failing. Collapsing them into one is how a card ends up lying.
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if snapshot.inferenceConfigured, snapshot.inferenceError == nil {
                        ProgressView().controlSize(.mini)
                    } else if snapshot.inferenceConfigured {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 10))
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(.orange)
                    } else {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 10))
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(.tertiary)
                    }
                    Text(
                        !snapshot.inferenceConfigured
                            ? "未配置推理端点"
                            : (snapshot.inferenceError == nil ? "正在探测推理端点…" : "推理端点无响应")
                    )
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.secondary)
                }
                Text(
                    snapshot.inferenceError
                        ?? (snapshot.inferenceConfigured
                            ? "首次探测需要几秒"
                            : "在设置里填该机的推理端点 URL（可点“扫描”自动发现）")
                )
                .font(.system(size: 9.5, design: .rounded))
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
                    .foregroundStyle(.quaternary)
            )
        }
    }

    /// The scan proposes, the user decides. A port scan cannot tell an idle
    /// leftover from a live endpoint, so every service found on the machine is
    /// listed here alongside "自动" and "不显示".
    private var sourceMenu: some View {
        Menu {
            Picker("", selection: Binding(
                get: { inferenceSource },
                set: { onChooseSource($0) }
            )) {
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
            Label(sourceLabel, systemImage: "arrow.triangle.branch")
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .labelStyle(.titleAndIcon)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("选择这一台显示的推理服务（扫描到的服务可手动指定）")
    }

    private var sourceLabel: String {
        switch inferenceSource {
        case .auto: "来源"
        case let .pinned(url):
            url.split(separator: ":").last.map { ":\($0)" } ?? "固定"
        case .hidden: "已隐藏"
        }
    }

    /// Speed readout: a live number + trend while it is decoding, the engine's
    /// own native rate when it has one, otherwise "空闲" for a counter-based
    /// engine or nothing for an engine that cannot report speed at all.
    @ViewBuilder
    private func speedBadge(_ inference: InferenceSample) -> some View {
        let state = SpeedDisplay.state(
            rate: inference.decodeTPS,
            age: inference.decodeTPSAge,
            running: inference.running
        )
        if let tps = inference.decodeTPS, state != .hidden {
            // Green = measured now. Grey = the last measurement, with how long ago
            // it was: the number is still true, the claim "live" is not. The
            // sparkline follows the same colour so the trend cannot look active
            // while the value is stale.
            let tint: Color = state == .live ? .green : .secondary
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                NumberUnit(
                    value: String(format: "%.0f", tps),
                    unit: "tok/s",
                    size: 19,
                    unitSize: 9.5,
                    tint: tint,
                    weight: .semibold
                )
                if state == .stopped, let age = inference.decodeTPSAge, age >= 1 {
                    Text(age >= 60
                         ? String(format: "已停 %.0f 分", age / 60)
                         : String(format: "已停 %.0f 秒", age))
                        .font(.system(size: 9.5, design: .rounded))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
                Sparkline(values: history.tps, tint: tint)
                    .frame(width: 72, height: 18)
            }
        } else if inference.capabilities.hasSpeed || inference.capabilities.hasTokenCounters {
            Text(inference.decodeTPS != nil ? "已停止" : "空闲")
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .foregroundStyle(.tertiary)
        }
    }

    private var containerRow: some View {
        HStack(spacing: 5) {
            Image(systemName: "shippingbox")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            ForEach(snapshot.system.containers.prefix(3), id: \.name) { container in
                Chip(text: container.name, tint: .teal)
            }
            if snapshot.system.containers.count > 3 {
                Chip(text: "+\(snapshot.system.containers.count - 3)", tint: .secondary)
            }
            Spacer()
        }
    }

    private var healthRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(snapshot.health.reasons.prefix(3), id: \.self) { reason in
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8.5))
                        .foregroundStyle(palette.accent(for: snapshot.health.level))
                    Text(reason)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.top, 2)
    }

    private func formatTokens(_ value: Double) -> String {
        value >= 1_000_000 ? String(format: "%.1fM", value / 1_000_000)
            : value >= 1_000 ? String(format: "%.1fk", value / 1_000)
            : String(format: "%.0f", value)
    }
}

// MARK: - Popover content

struct PopoverView: View {
    @ObservedObject var model: AppModel
    /// Opens the settings window. Defaulted so previews and tests can ignore it.
    var onOpenSettings: () -> Void = {}
    var onTogglePause: () -> Void = {}
    /// Opens the detail window, optionally focused on one machine. Optional so
    /// previews and tests can render without a window server round trip; the
    /// fallback is the real window.
    var onOpenDetail: ((UUID?) -> Void)?
    @State private var loginNode: NodeSnapshot?
    @State private var shutdownNode: NodeSnapshot?
    /// Live appearance, so 跟随系统 actually follows the Mac's light/dark setting
    /// while the popover is open.
    @Environment(\.colorScheme) private var colorScheme

    /// Resolved tokens for this render. Passed down explicitly rather than read
    /// from the environment: the same views also render offscreen (previews and
    /// `--preview`), where there is no window appearance to resolve against.
    private var palette: Palette {
        Palette.of(model.theme, dark: colorScheme == .dark)
    }

    private func openDetail(_ nodeID: UUID?) {
        if let onOpenDetail {
            onOpenDetail(nodeID)
        } else {
            DetailWindowManager.shared.show(model: model, focusing: nodeID)
        }
    }

    // MARK: - Capacity (N machines, never squeezed)
    //
    // The popover never scrolls, and this is arithmetic rather than hope: the
    // card height is fixed and the chrome around it is measured, so a
    // 1440×900 screen fits two cards and a 2560×1440 one fits four. Whatever is
    // left over becomes a single explicit row that opens the main window — a
    // scrolling popover hides exactly the machine you opened it to look at.
    // (First draft of this layout measured 948 pt for two machines, which is how
    // the 284 pt card height and the 7 pt rhythm below were arrived at.)

    /// How many machines fit. One rule, in `Theme.cardCapacity`, so the popover
    /// and the verification printout cannot disagree about it.
    private var visibleCount: Int {
        guard !model.nodes.isEmpty else { return 0 }
        return min(model.nodes.count, Theme.cardCapacity(available: Theme.availableHeight))
    }

    private var visibleNodes: [NodeSnapshot] { Array(model.nodes.prefix(visibleCount)) }
    private var hiddenCount: Int { max(0, model.nodes.count - visibleNodes.count) }

    /// Every card is the same shape, so they line up by construction — no
    /// measured equalisation, and no way for one machine's data to change the
    /// popover's height.
    private var cardGrid: some View {
        VStack(spacing: 7) {
            ForEach(visibleNodes) { snapshot in
                CompactCard(
                    snapshot: snapshot,
                    coveredByTask: taskCoveredNames.contains(snapshot.name),
                    powerEstimate: model.powerEstimate,
                    powerWindowSeconds: model.powerWindowSeconds,
                    inferenceSource: model.inferenceSource(for: snapshot.id),
                    onChooseSource: { source in
                        Task { await model.setInferenceSource(nodeID: snapshot.id, source: source) }
                    },
                    onExpand: { openDetail(snapshot.id) },
                    onLogin: { loginNode = snapshot },
                    onShutdown: { shutdownNode = snapshot },
                    palette: palette,
                    trends: model.history[snapshot.id]?.tps ?? []
                )
            }
            if hiddenCount > 0 { overflowRow }
        }
    }

    /// Machines whose model and role the banner already states. Matching is by
    /// name as well as short name: the process table reports `spark-00`, a
    /// hand-configured node may be called anything.
    private var taskCoveredNames: Set<String> {
        TaskSummary.coveredNames(in: model.tasks)
    }

    /// One line, not a button block: at 780 pt of room the cards plus this row
    /// have to fit, and every point this row spends is a point stolen from the
    /// machine that did not fit (measured: a bordered/padded version pushed the
    /// 3-machine popover to 792 pt, past the 780 pt budget).
    private var overflowRow: some View {
        Button {
            openDetail(nil)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "ellipsis.circle").font(.system(size: 10))
                Text("还有 \(hiddenCount) 台未显示（共 \(model.nodes.count) 台）· 打开主窗口")
                    .font(.system(size: 10.5, design: .rounded))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("popover 只显示放得下的机器，其余在主窗口里")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.5)
            bannerArea
            cardGrid
                .padding(.horizontal, Theme.gutter)
                .padding(.vertical, 9)
            Divider().opacity(0.5)
            footer
        }
        .frame(width: Theme.popoverWidth)
        .background(Palette.chrome(model.theme, dark: colorScheme == .dark))
        .sheet(item: $loginNode) { snapshot in
            LoginSheet(
                snapshot: snapshot,
                defaultUsername: model.signedInUsername(nodeID: snapshot.id) ?? snapshot.host.split(separator: "-").first.map(String.init) ?? "user"
            ) { username, password in
                await model.login(nodeID: snapshot.id, username: username, password: password)
            }
        }
        .sheet(item: $shutdownNode) { node in
            ShutdownSheet(
                node: node,
                config: model.nodeConfigs.first { $0.name == node.name || $0.sshHost == node.host },
                palette: palette
            ) { message in
                if let message {
                    model.noteAction(message, severity: .warn, kind: "node.shutdown", node: node)
                }
            }
        }
    }

    /// The deployment banner states the shared facts exactly once: what is being
    /// served, how the machines are wired together, who serves and who does not,
    /// the deployment-wide rate and the deployment-wide power. The cards below
    /// then say nothing about the model at all.
    @ViewBuilder
    private var bannerArea: some View {
        if let task = model.tasks.first, model.tasks.count == 1 {
            TaskBanner(
                task: task,
                powerW: TaskSummary.powerW(
                    for: task, in: model.nodes, powerEstimate: model.powerEstimate
                ),
                activity: TaskSummary.activity(for: task, in: model.nodes),
                palette: palette
            )
            .padding(.horizontal, Theme.gutter)
            .padding(.top, 9)
        } else if model.tasks.count > 1 {
            // Several deployments at once: name them in one line rather than
            // stacking banners; the main window lists each in full.
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(palette.accent)
                Text("\(model.tasks.count) 个并行任务："
                    + model.tasks.prefix(3).map(\.model).joined(separator: "、")
                    + (model.tasks.count > 3 ? " 等" : ""))
                    .font(.system(size: 10.5, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(palette.accentSoft))
            .padding(.horizontal, Theme.gutter)
            .padding(.top, 9)
        }
    }

    /// The worst level across the fleet — the header dot answers "do I need to
    /// look at this at all", so it has to be the worst, not the first.
    private var worstLevel: HealthLevel {
        if model.nodes.contains(where: { $0.source == .down }) { return .critical }
        if model.nodes.contains(where: { $0.health.level == .critical }) { return .critical }
        if model.nodes.contains(where: { $0.health.level == .warning }) { return .warning }
        if model.nodes.isEmpty { return .unknown }
        return .ok
    }

    private var header: some View {
        HStack(spacing: 7) {
            StatusDot(level: worstLevel, palette: palette)
            Text("SparkWatch")
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
            let alive = model.nodes.filter { $0.source != .down }.count
            Chip(text: "\(alive)/\(model.nodes.count) 在线",
                 tint: alive == model.nodes.count ? palette.ok : palette.warn)
            // Said once, at the top: how many machines are waiting for a password.
            // Without it the state is only visible per card, and the whole point
            // of this change is that it stops being invisible.
            let awaiting = model.nodes.filter(\.awaitingCredentials).count
            if awaiting > 0 {
                Chip(text: "\(awaiting) 台需登录", tint: palette.warn)
            }
            Spacer(minLength: 4)
            Text(String(format: "Live · %.0f s", model.pollSeconds))
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.tertiary)
                .help("采集周期。忙碌时推理探测会加密到 2 秒，空闲时放宽到 6 秒")
            headerButton("主窗口") { openDetail(nil) }
                .help("打开主窗口 (⌘D)")
            headerButton(model.isPaused ? "恢复" : "暂停") { onTogglePause() }
                .help("暂停/恢复监控 (⌘P)")
            Text(model.lastUpdate, style: .time)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 8)
    }

    private func headerButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, design: .rounded))
                .foregroundStyle(palette.accentText)
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            // `awaitingCredentials` matters as much as `down` here: a node whose
            // official channel is off still shows numbers (SSH fallback), so its
            // login button used to be hidden behind a state it never entered —
            // 2026-10-16, the popover offered no way to fix the very condition the
            // menu bar was about to name.
            ForEach(model.nodes.filter { $0.source == .down || $0.awaitingCredentials }) { snapshot in
                Button("登录 \(snapshot.name)") { loginNode = snapshot }
                    .controlSize(.small)
            }
            Spacer(minLength: 0)
            Button("设置…") { onOpenSettings() }
                .controlSize(.small)
            Button("退出") { NSApplication.shared.terminate(nil) }
                .controlSize(.small)
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }
}

// MARK: - Login sheet

struct LoginSheet: View {
    var snapshot: NodeSnapshot
    var defaultUsername: String
    var onSubmit: (String, String) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var username: String
    @State private var password = ""
    @State private var error: String?
    @State private var busy = false

    init(snapshot: NodeSnapshot, defaultUsername: String, onSubmit: @escaping (String, String) async -> String?) {
        self.snapshot = snapshot
        self.defaultUsername = defaultUsername
        self.onSubmit = onSubmit
        _username = State(initialValue: defaultUsername)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(.blue)
                Text("登录 \(snapshot.name)")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            Text("使用该机器的系统账号（与 DGX Dashboard 网页版相同）。密码不会保存，仅保存 14 天有效的会话令牌。")
                .font(.system(size: 10.5, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                TextField("用户名", text: $username)
                SecureField("密码", text: $password)
            }
            .formStyle(.grouped)
            .frame(height: 96)

            if let error {
                Text(error)
                    .font(.system(size: 10.5, design: .rounded))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button(busy ? "登录中…" : "登录") {
                    busy = true
                    Task {
                        let failure = await onSubmit(username, password)
                        busy = false
                        error = failure
                        if failure == nil { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty || busy)
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}
