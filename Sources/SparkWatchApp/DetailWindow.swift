import AppKit
import SparkWatchCore
import SwiftUI

/// Shared, observable state for the detail window.
///
/// Separate from `AppModel` because it is window-local: which machine is
/// focused, and whether the user wants everything at once. Keeping it out of the
/// model means the popover's rendering never depends on a window being open.
@MainActor
final class DetailState: ObservableObject {
    /// `nil` = show every machine side by side.
    @Published var focus: UUID?
    /// Machines, in the order the popover shows them. Cached so the picker can
    /// label devices without the view reaching into the model.
    @Published var labels: [(id: UUID, name: String)] = []
    @Published var lastUpdate: Date = .distantPast
}

/// The detail window: one resizable, non-modal surface that holds *everything*.
///
/// This is where the rich per-machine card lives — health reasons, PSI, page
/// cache, containers, the whole stat grid. Putting it here rather than in the
/// popover is the entire point of the redesign: a popover is for a small amount
/// of information (HIG, Popovers), and a squeezed popover is what made text
/// overlap. A window can be resized, scrolled, and left open, so nothing ever
/// has to be compressed to fit.
///
/// Fleet scaling: columns scroll horizontally instead of shrinking, the picker
/// scales to any number of machines, and ⌘1…⌘9 focus the first nine so a large
/// fleet stays keyboard-reachable.
@MainActor
final class DetailWindowManager {
    static let shared = DetailWindowManager()

    private var window: NSWindow?
    private var state: DetailState?
    private weak var model: AppModel?

    var isVisible: Bool { window?.isVisible == true }

    func show(model: AppModel, focusing nodeID: UUID? = nil) {
        self.model = model
        if window == nil { build(model: model) }
        if let nodeID { state?.focus = nodeID }
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() { window?.close() }

    /// Keep the detail window's native controls on the same theme as the
    /// popover. `nil` means "follow the Mac", which is `AppTheme.system`.
    func applyAppearance(_ appearance: NSAppearance?) {
        window?.appearance = appearance
    }

    /// Forget the remembered frame and centre the window again. Needed because a
    /// frame saved by an older version (or by a display that is no longer
    /// attached) can leave the window off-centre or off-screen with no obvious
    /// way back — a window you cannot re-centre is a trap.
    func resetPosition() {
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame SparkWatchDetailWindow")
        if let window {
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// A frame restored from a display that is no longer attached can land
    /// entirely off-screen; pull it back into view rather than showing nothing.
    private func clampToScreen(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var frame = window.frame
        guard frame.intersects(visible) else {
            window.center()
            return
        }
        frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        if frame != window.frame { window.setFrame(frame, display: false) }
    }

    private func build(model: AppModel) {
        let state = DetailState()
        self.state = state

        let hosting = NSHostingController(
            rootView: DetailView(model: model, state: state, onClose: { [weak self] in self?.close() })
        )
        // Default size from the screen, not a constant: a laptop and a 4K
        // display should not get the same window.
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let defaultSize = NSSize(
            width: min(1180, visible.width - 120),
            height: min(820, visible.height - 160)
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "SparkWatch 详情"
        window.isReleasedWhenClosed = false      // reopenable, and cheap to keep
        window.minSize = NSSize(width: 420, height: 380)
        window.contentViewController = hosting
        // Assigning a content view controller makes AppKit resize the window to
        // the view's fitting size — which for a view declaring only minimums is
        // the minimum. Ask for the intended size *after* that, otherwise the
        // window opens as a 420x380 postage stamp.
        window.setContentSize(defaultSize)
        // Remembers position and size between launches — a monitoring window
        // people park on a second display must come back where they left it.
        //
        // Whether a frame was *already* saved has to be asked before installing
        // the autosave name: `setFrameAutosaveName` writes the current frame
        // straight away, so checking afterwards always says "saved" and the
        // window never gets centred. (The previous version tested
        // `frame.origin == .zero`, which AppKit had already moved to (0, 91)
        // while swapping in the content view controller — hence a window glued
        // to the top-left corner.)
        let hadSavedFrame = UserDefaults.standard
            .string(forKey: "NSWindow Frame SparkWatchDetailWindow") != nil
        window.setFrameAutosaveName("SparkWatchDetailWindow")
        if !hadSavedFrame {
            window.center()
        } else {
            clampToScreen(window)
        }
        self.window = window
    }

    /// Whether a key event belongs to the detail window. Only when it is key
    /// and visible, so a ⌘-shortcut in the popover is never swallowed.
    func wantsKey(_ event: NSEvent) -> Bool {
        guard window?.isKeyWindow == true, window?.isVisible == true else { return false }
        return event.modifierFlags.contains(.command)
    }

    /// ⌘1…⌘9 / ⌘0, handled here so the bindings work wherever focus is inside
    /// the window (a SwiftUI keyboardShortcut on a segmented control would only
    /// fire while that control has focus).
    func handleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command), let state else { return false }
        let characters = event.charactersIgnoringModifiers ?? ""
        if characters == "0" {
            state.focus = nil
            return true
        }
        guard let digit = Int(characters), digit >= 1, digit <= 9 else { return false }
        // ⌘N maps to the Nth machine *in the current order*, not to a stored
        // index, so it keeps working as machines come and go.
        guard state.labels.indices.contains(digit - 1) else { return false }
        state.focus = state.labels[digit - 1].id
        return true
    }
}

struct DetailView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: DetailState
    var onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    /// Same tokens as the popover, resolved the same way, so the two surfaces
    /// cannot disagree about what "warning" looks like.
    private var palette: Palette {
        Palette.of(model.theme, dark: colorScheme == .dark)
    }

    @State private var loginNode: NodeSnapshot?
    /// Measured content width, captured from the GeometryReader so the footer can
    /// report how many machines are scrolled off without re-measuring.
    @State private var contentWidth: CGFloat = 0

    private var focused: NodeSnapshot? {
        guard let focus = state.focus else { return nil }
        return model.nodes.first { $0.id == focus }
    }

    /// All machines, or just the focused one.
    private var shown: [NodeSnapshot] {
        guard let focus = state.focus else { return model.nodes }
        let match = model.nodes.filter { $0.id == focus }
        return match.isEmpty ? model.nodes : match
    }

    /// Offscreen rendering (ImageRenderer) gives a ScrollView no size, so the
    /// preview path renders the same content without the scroll containers.
    /// `--preview-detail` therefore checks the layout; the real window is checked
    /// by screenshotting it.
    var scrolls: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            Divider()
            if scrolls {
                ScrollView(.vertical) { sizedBody }
            } else {
                sizedBody
            }
            Divider()
            statusFooter
        }
        .frame(
            minWidth: 420, idealWidth: 1020,
            minHeight: 380, idealHeight: 720
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $loginNode) { snapshot in
            LoginSheet(
                snapshot: snapshot,
                defaultUsername: model.signedInUsername(nodeID: snapshot.id)
                    ?? snapshot.host.split(separator: "-").first.map(String.init)
                    ?? "user"
            ) { username, password in
                await model.login(nodeID: snapshot.id, username: username, password: password)
            }
        }
        .onAppear { syncLabels() }
        .onChange(of: model.nodes.map(\.id)) { _, _ in syncLabels() }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up.fill")
                .foregroundStyle(.teal)
            Text("集群详情")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
            Text(onlineSummary)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            // Scales past a handful of machines: a segmented control would be
            // unusable at twelve, a popup menu is not.
            Picker("", selection: Binding(
                get: { state.focus },
                set: { state.focus = $0 }
            )) {
                Text("全部机器 (\(model.nodes.count))").tag(UUID?.none)
                ForEach(state.labels, id: \.id) { entry in
                    Text(entry.name).tag(UUID?.some(entry.id))
                }
            }
            .labelsHidden()
            .frame(width: 200)
            .help("⌘1…⌘9 直接切到第 N 台，⌘0 回到全部")

            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("立即刷新 (⌘R)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var statusFooter: some View {
        HStack(spacing: 10) {
            if let error = model.nodes.compactMap(\.error).first {
                Label(error.prefix(60), systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if layout.overflow > 0 {
                Label("另有 \(layout.overflow) 台在右侧，横向滚动查看", systemImage: "arrow.left.and.right")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Text("更新于 \(state.lastUpdate.formatted(date: .omitted, time: .standard))")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(.tertiary)
            Button("关闭") { onClose() }
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    // MARK: - Columns

    /// Measures the content area so the columns can be laid out to a rule
    /// instead of to whatever SwiftUI happens to do with `maxWidth: .infinity`.
    private var sizedBody: some View {
        GeometryReader { proxy in
            let layout = LayoutPolicy.detailLayout(
                nodeCount: shown.count,
                contentWidth: max(0, proxy.size.width - 28)
            )
            VStack(alignment: .leading, spacing: 12) {
                if !model.tasks.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(model.tasks) { task in
                            TaskBanner(
                                task: task,
                                powerW: TaskSummary.powerW(
                                    for: task, in: model.nodes,
                                    powerEstimate: model.powerEstimate
                                ),
                                activity: TaskSummary.activity(for: task, in: model.nodes)
                            )
                        }
                    }
                }
                columns(layout)
            }
            .padding(14)
            .frame(width: proxy.size.width, alignment: .top)
            .onAppear { contentWidth = proxy.size.width }
            .onChange(of: proxy.size.width) { _, width in contentWidth = width }
        }
    }

    /// Columns: equal width, centred as a group, scrolling when a fleet does
    /// not fit side by side. Never squeezed — a crushed card is worse than a
    /// scrollbar, and this window exists precisely to have room.
    @ViewBuilder
    private func columns(_ layout: LayoutPolicy.DetailLayout) -> some View {
        if layout.overflow > 0, scrolls {
            // The fleet is wider than the window: scroll it, centred within the
            // scroll content so the first card is not jammed against the edge.
            ScrollView(.horizontal, showsIndicators: true) {
                columnRow(layout)
                    .padding(.horizontal, max(0, (contentWidth - 28 - CGFloat(layout.groupWidth)) / 2))
            }
        } else if layout.overflow > 0 {
            // Offscreen preview: ImageRenderer gives a ScrollView no size, so
            // the row is drawn directly (clipped) — real scrolling is verified by
            // screenshotting the window, not by the render.
            columnRow(layout)
        } else {
            // Everything fits: split the leftover space evenly instead of leaving
            // it all on the right. Uneven margins are what read as "off centre".
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                columnRow(layout)
                Spacer(minLength: 0)
            }
        }
    }

    private func columnRow(_ layout: LayoutPolicy.DetailLayout) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(shown) { snapshot in
                VStack(alignment: .leading, spacing: 8) {
                    if shown.count > 1 {
                        Text(snapshot.name)
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    NodeCard(
                        snapshot: snapshot,
                        history: model.history[snapshot.id] ?? AppModel.History(),
                        powerWindowSeconds: model.powerWindowSeconds,
                        inferenceSource: model.inferenceSource(for: snapshot.id),
                        onChooseSource: { source in
                            Task { await model.setInferenceSource(nodeID: snapshot.id, source: source) }
                        },
                        powerEstimate: model.powerEstimate,
                        palette: palette,
                        onLogin: { loginNode = snapshot },
                        onSignOut: {}
                    )
                }
                .frame(width: CGFloat(layout.columnWidth))
            }
        }
    }

    // MARK: - Derived

    /// Recomputed for the footer from the last measured width — pure, so it does
    /// not mutate state while the body is being evaluated.
    private var layout: LayoutPolicy.DetailLayout {
        LayoutPolicy.detailLayout(
            nodeCount: shown.count,
            contentWidth: max(0, contentWidth - 28)
        )
    }

    private var onlineSummary: String {
        let alive = model.nodes.filter { $0.source != .down }.count
        var parts = ["\(alive)/\(model.nodes.count) 在线"]
        if let task = model.tasks.first {
            parts.append(task.isParallel ? "\(task.model) · \(task.topologyLabel)" : task.model)
        }
        if model.tasks.count > 1 { parts.append("共 \(model.tasks.count) 个任务") }
        return parts.joined(separator: " · ")
    }

    private func syncLabels() {
        state.labels = model.nodes.map { ($0.id, $0.name) }
        state.lastUpdate = model.lastUpdate
        // A machine that disappeared must not leave the picker focused on a
        // ghost — fall back to showing everything.
        if let focus = state.focus, !model.nodes.contains(where: { $0.id == focus }) {
            state.focus = nil
        }
    }
}
