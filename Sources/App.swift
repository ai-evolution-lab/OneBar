import SwiftUI
import AppKit
import Combine
import ServiceManagement

@main
enum OneBarEntry {
    static func main() {
        let args = CommandLine.arguments
        if args.count >= 2, args[1] == "helper" {
            exit(HelperCLI.run(args))
        }
        if args.count >= 2, args[1] == "selftest" {
            exit(FanCurve.runSelfTest())
        }
        if args.count >= 2, args[1] == "snapshot" {
            exit(Snapshotter.run(outputDir: args.count >= 3 ? args[2] : NSTemporaryDirectory()))
        }
        if args.count >= 2, args[1] == "snapshot-popover" {
            exit(Snapshotter.runPopover(outputDir: args.count >= 3 ? args[2] : NSTemporaryDirectory()))
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var state: AppState?
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let state = AppState()
        self.state = state
        statusBar = StatusBarController(state: state)
    }

    func applicationWillTerminate(_ notification: Notification) {
        state?.fan.restoreAutoOnQuit()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@MainActor
final class StatusBarController: NSObject {
    private let state: AppState
    private let memoryItem: NSStatusItem
    private let fanItem: NSStatusItem
    private let clipItem: NSStatusItem
    private let memoryPopover = NSPopover()
    private let fanPopover = NSPopover()
    private var clipWindow: ClipboardWindowController?
    private var cancellables = Set<AnyCancellable>()

    init(state: AppState) {
        self.state = state
        memoryItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        fanItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        clipItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configure(memoryItem, title: state.memory.menuTitle, action: #selector(toggleMemory(_:)))
        configure(fanItem, title: state.fan.menuTitle, action: #selector(toggleFan(_:)))
        if let button = clipItem.button {
            button.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "剪贴板")
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(toggleClipboard(_:))
        }
        embed(MemoryPanel().environmentObject(state), in: memoryPopover)
        embed(
            FanPanel().environmentObject(state).environmentObject(state.fan),
            in: fanPopover
        )
        clipWindow = ClipboardWindowController(state: state)
        state.clipboardWindow = clipWindow
        HotKeyCenter.shared.setHandler { [weak self] in
            self?.clipWindow?.toggle()
        }
        HotKeyCenter.shared.register(state.clipboard.hotKey)
        state.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refreshTitles() }
            }
            .store(in: &cancellables)
        refreshTitles()
    }

    private func configure(_ item: NSStatusItem, title: String, action: Selector) {
        item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        item.button?.title = title
        item.button?.target = self
        item.button?.action = action
    }

    private func embed<V: View>(_ view: V, in popover: NSPopover) {
        popover.contentViewController = Self.makePanelHost(view)
        popover.behavior = .transient
        popover.animates = false
    }

    /// `.preferredContentSize` (not `.intrinsicContentSize`) is what NSPopover actually
    /// sizes itself from; with the wrong option the popover keeps a stale size and the
    /// panel gets clipped at the popover edges.
    static func makePanelHost<V: View>(_ view: V) -> NSHostingController<V> {
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]
        return host
    }

    /// Popovers only adopt the content size at show time; make sure it matches the panel.
    private func syncPopoverSize(_ popover: NSPopover) {
        guard let view = popover.contentViewController?.view else { return }
        let fitting = view.fittingSize
        if fitting.width > 1, fitting.height > 1 { popover.contentSize = fitting }
    }

    private func refreshTitles() {
        memoryItem.button?.title = state.memory.menuTitle
        fanItem.button?.title = state.fan.menuTitle
    }

    @objc private func toggleMemory(_ sender: Any?) { toggle(memoryPopover, from: memoryItem) }
    @objc private func toggleFan(_ sender: Any?) { toggle(fanPopover, from: fanItem) }
    @objc private func toggleClipboard(_ sender: Any?) {
        memoryPopover.performClose(nil)
        fanPopover.performClose(nil)
        clipWindow?.toggle()
    }

    private func toggle(_ popover: NSPopover, from item: NSStatusItem) {
        let wasOpen = popover.isShown
        memoryPopover.performClose(nil)
        fanPopover.performClose(nil)
        clipWindow?.hide()
        guard !wasOpen, let button = item.button else { return }
        if popover == fanPopover { state.fan.clearTransientFeedback() }
        syncPopoverSize(popover)
        button.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if let window = popover.contentViewController?.view.window {
            window.makeKey()
            window.makeFirstResponder(nil)
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var memory = MemorySnapshot.zero
    @Published var memoryTop: [ProcessMemoryEntry] = []
    @Published var launchAtLogin: Bool
    let clipboard = ClipboardStore()
    let fan = FanController()
    weak var clipboardWindow: ClipboardWindowController?

    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var tickCount = 0

    init() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        memory = MemorySampler.sample()
        fan.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        clipboard.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        refreshMemoryTop()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.memory = MemorySampler.sample()
                self.tickCount += 1
                if self.tickCount % 3 == 0 { self.refreshMemoryTop() }
            }
        }
    }

    /// Per-process sampling walks every PID; do it off-main and at a slower cadence.
    private func refreshMemoryTop() {
        Task.detached(priority: .utility) {
            let top = MemorySampler.topProcesses(limit: 10)
            await MainActor.run { [weak self] in self?.memoryTop = top }
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    func hideClipboard() {
        clipboardWindow?.hide()
    }

    func quit() {
        fan.restoreAutoOnQuit()
        NSApp.terminate(nil)
    }
}

private struct PanelChrome<Content: View>: View {
    var viewportHeight: CGFloat
    @ViewBuilder var content: Content
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 12) {
                    content
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: viewportHeight)
            .scrollBounceBehavior(.basedOnSize)
            Divider()
            HStack {
                Toggle("开机启动", isOn: Binding(
                    get: { state.launchAtLogin },
                    set: { state.setLaunchAtLogin($0) }
                ))
                .toggleStyle(.checkbox)
                Spacer()
                Button {
                    state.quit()
                } label: {
                    Label("退出", systemImage: "power")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .font(.caption)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 360)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct MemoryPanel: View {
    @EnvironmentObject var state: AppState

    /// Matches MemoryPanelContent's natural height + its 14pt paddings, so the
    /// fixed viewport hugs the content without a dead gap under the last card.
    static let viewportHeight: CGFloat = MemoryPanelContent.height + 28

    var body: some View {
        PanelChrome(viewportHeight: Self.viewportHeight) {
            MemoryPanelContent()
        }
    }
}

private struct MemoryPanelContent: View {
    @EnvironmentObject var state: AppState

    /// Measured natural height of the layout below (header card + usage card +
    /// Top 10 card + gaps). Update together with the rows below.
    static let height: CGFloat = 517

    var body: some View {
        let mem = state.memory
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(String(format: "%.0f", mem.usedPercent))
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("%")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label(mem.pressure.title, systemImage: mem.pressure == .normal ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(mem.pressure == .normal ? Color.secondary : Color.orange)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        (mem.pressure == .normal ? Color.secondary : Color.orange).opacity(0.12),
                        in: Capsule()
                    )
            }
            VStack(spacing: 0) {
                row("已用", bytes: mem.usedBytes, total: mem.totalBytes)
                divider
                row("应用", bytes: mem.appBytes)
                divider
                row("已联动", bytes: mem.wiredBytes)
                divider
                row("压缩", bytes: mem.compressedBytes)
                divider
                row("交换", bytes: mem.swapUsedBytes)
            }
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            topProcessesCard
        }
    }

    /// Top consumers by phys_footprint — same metric as Activity Monitor's 内存 column.
    private var topProcessesCard: some View {
        VStack(spacing: 0) {
            HStack {
                Text("进程占用 Top 10")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("物理占用")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            divider
            if state.memoryTop.isEmpty {
                Text("正在统计…")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(state.memoryTop.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { divider }
                        processRow(rank: index + 1, entry: entry)
                    }
                }
            }
        }
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    private func processRow(rank: Int, entry: ProcessMemoryEntry) -> some View {
        HStack(spacing: 8) {
            Text("\(rank)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 16, alignment: .center)
            Text(entry.name)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(formatBytes(entry.bytes))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary.opacity(0.85))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private var divider: some View {
        Divider().overlay(Color.primary.opacity(0.06))
    }

    private func row(_ title: String, bytes: UInt64, total: UInt64? = nil) -> some View {
        HStack {
            Text(title)
            Spacer()
            if let total {
                Text("\(formatBytes(bytes)) / \(formatBytes(total))")
            } else {
                Text(formatBytes(bytes))
            }
        }
        .font(.callout)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

private struct FanPanel: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var fan: FanController

    var body: some View {
        PanelChrome(viewportHeight: 470) {
            if let error = fan.errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.callout)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            } else {
                tempHeader
                fanCard
                strategyPicker
                modeControls
                statusFootnotes
            }
        }
    }

    private var tempHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(fan.cpuTemp.map { String(format: "%.0f", $0) } ?? "--")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("°C")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Text("CPU")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text("全机最高")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(fan.hottestTemp.map { String(format: "%.0f°C", $0) } ?? "--")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [Color.accentColor.opacity(0.16), Color.accentColor.opacity(0.05)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.07))
        )
    }

    private var fanCard: some View {
        VStack(spacing: 0) {
            ForEach(fan.fans) { item in
                fanRow(item)
                if item.id != fan.fans.count - 1 {
                    Divider().overlay(Color.primary.opacity(0.06))
                }
            }
        }
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    private func fanRow(_ item: FanInfo) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(item.isManual ? Color.accentColor : Color.secondary.opacity(0.35))
                .frame(width: 7, height: 7)
            Text("风扇 \(item.id)")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Text(String(format: "%.0f", item.actualRPM))
                .font(.system(.callout, design: .monospaced).weight(.semibold))
                .monospacedDigit()
                .frame(width: 50, alignment: .trailing)
            Text(String(format: "%.0f–%.0f", item.minRPM, item.maxRPM))
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var strategyPicker: some View {
        HStack(spacing: 10) {
            Text("策略")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Picker("策略", selection: Binding(
                get: { fan.mode },
                set: { newValue in
                    switch newValue {
                    case .auto: fan.selectAuto()
                    case .fixed: fan.selectFixed()
                    case .curve: fan.selectCurve()
                    }
                }
            )) {
                Text("自动").tag(FanMode.auto)
                Text("固定").tag(FanMode.fixed)
                Text("曲线").tag(FanMode.curve)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var modeControls: some View {
        if fan.mode == .fixed {
            FixedSpeedControls(fan: fan)
        }
        if fan.mode == .curve {
            CurveControls(fan: fan)
        }
    }

    @ViewBuilder
    private var statusFootnotes: some View {
        VStack(alignment: .leading, spacing: 4) {
            if fan.applying {
                Label("正在写入…", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if fan.passwordless {
                Label("已授权，切换策略不再要密码。", systemImage: "checkmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    Button("授权风扇控制（仅一次）") { fan.authorize() }
                        .controlSize(.small)
                    Text("首次输入密码后写入系统授权。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let other = fan.competitor {
                Label("\(other) 正在运行，会抢风扇控制。", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if fan.needsAdmin {
                Label("授权失败，请再点一次「授权风扇控制」。", systemImage: "xmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let writeError = fan.writeError {
                Label(writeError, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}

private struct FixedSpeedControls: View {
    @ObservedObject var fan: FanController
    @State private var draft: Double = 0
    @State private var rpmText = ""
    @State private var dragging = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("目标")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 26, alignment: .leading)
                RPMSlider(
                    value: draft,
                    minValue: fan.sliderMin,
                    maxValue: max(fan.sliderMax, fan.sliderMin + 1),
                    onLiveChange: { value in
                        if !dragging {
                            dragging = true
                            fan.beginSpeedEdit()
                        }
                        draft = value
                        if !fieldFocused { rpmText = String(format: "%.0f", value) }
                    },
                    onEnded: { value in
                        dragging = false
                        draft = value
                        rpmText = String(format: "%.0f", value)
                        fan.applyFixed(rpm: value)
                    }
                )
                .frame(minHeight: 22)
                TextField("", text: $rpmText)
                    .textFieldStyle(.plain)
                    .font(.system(.callout, design: .monospaced))
                    .monospacedDigit()
                    .multilineTextAlignment(.center)
                    .frame(width: 66)
                    .padding(.vertical, 4)
                    .background(
                        Color.primary.opacity(fieldFocused ? 0.1 : 0.07),
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(fieldFocused ? Color.accentColor.opacity(0.8) : Color.primary.opacity(0.06))
                    )
                    .focused($fieldFocused)
                    .onSubmit { commitText() }
                    .onChange(of: fieldFocused) { _, focused in
                        if focused {
                            fan.beginSpeedEdit()
                        } else {
                            commitText()
                        }
                    }
            }
            Text("两颗风扇共用这个目标，超出各自上下限时自动钳位。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            draft = fan.fixedRPM
            rpmText = String(format: "%.0f", fan.fixedRPM)
        }
        .onChange(of: fan.fixedRPM) { _, newValue in
            if !dragging {
                draft = newValue
                if !fieldFocused { rpmText = String(format: "%.0f", newValue) }
            }
        }
    }

    /// Commit only on submit/focus-loss: editing stays untouched until the value is valid on purpose.
    private func commitText() {
        let cleaned = rpmText.filter { "0123456789".contains($0) }
        guard let value = Double(cleaned), value > 0 else {
            draft = fan.fixedRPM
            rpmText = String(format: "%.0f", fan.fixedRPM)
            return
        }
        fan.applyFixed(rpm: value)
    }
}

private struct CurveControls: View {
    @ObservedObject var fan: FanController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 7) {
                ForEach(fan.curvePoints.sorted(by: { $0.celsius < $1.celsius })) { point in
                    CurveRow(fan: fan, point: point)
                }
            }
            HStack {
                Button {
                    fan.addCurvePoint()
                } label: {
                    Label("添加条件", systemImage: "plus.circle.fill")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.accentColor)
                .disabled(fan.curvePoints.count >= 8)
                .opacity(fan.curvePoints.count >= 8 ? 0.4 : 1)
                Spacer()
                Text(String(format: "%.0f RPM", fan.curveTargetRPM))
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())
                    .foregroundStyle(Color.accentColor)
            }
            Text("按温度匹配最高满足的条件，低于全部阈值用最低转速。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// Edits stay in local drafts and commit on submit/focus-loss; writing the model on every
/// keystroke made clamped values (and the sorted row order) jump around mid-typing.
private struct CurveRow: View {
    @ObservedObject var fan: FanController
    let point: FanCurvePoint

    @State private var celsiusDraft = ""
    @State private var rpmDraft = ""
    @FocusState private var focusedField: Field?

    enum Field: Hashable {
        case celsius
        case rpm
    }

    var body: some View {
        HStack(spacing: 5) {
            Text("≥")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            field($celsiusDraft, width: 46, kind: .celsius, commit: commitCelsius)
            Text("°C")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .leading)
            Text("→")
                .font(.callout)
                .foregroundStyle(Color.secondary.opacity(0.5))
                .frame(width: 14)
            field($rpmDraft, width: 66, kind: .rpm, commit: commitRPM)
            Text("RPM")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .leading)
            Spacer(minLength: 4)
            Button {
                fan.removeCurvePoint(point.id)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .disabled(fan.curvePoints.count <= 1)
            .foregroundStyle(
                fan.curvePoints.count <= 1
                    ? Color.secondary.opacity(0.25)
                    : Color.secondary.opacity(0.6)
            )
        }
        .onAppear { syncDrafts() }
        .onChange(of: point) { _, _ in
            if focusedField == nil { syncDrafts() }
        }
        .onChange(of: focusedField) { _, field in
            if field != nil {
                fan.beginSpeedEdit()
            } else {
                commitAll()
            }
        }
    }

    private func field(
        _ text: Binding<String>,
        width: CGFloat,
        kind: Field,
        commit: @escaping () -> Void
    ) -> some View {
        let focused = focusedField == kind
        return TextField("", text: text)
            .textFieldStyle(.plain)
            .font(.system(.callout, design: .monospaced))
            .monospacedDigit()
            .multilineTextAlignment(.center)
            .focused($focusedField, equals: kind)
            .onSubmit { commit() }
            .frame(width: width)
            .padding(.vertical, 5)
            .background(
                Color.primary.opacity(focused ? 0.1 : 0.07),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(focused ? Color.accentColor.opacity(0.8) : Color.primary.opacity(0.06))
            )
    }

    private func syncDrafts() {
        celsiusDraft = String(format: "%.0f", point.celsius)
        rpmDraft = String(format: "%.0f", point.rpm)
    }

    private func commitCelsius() {
        let cleaned = celsiusDraft.filter { "0123456789".contains($0) }
        guard let value = Double(cleaned) else {
            celsiusDraft = String(format: "%.0f", point.celsius)
            return
        }
        fan.updateCurvePoint(id: point.id, celsius: value)
    }

    private func commitRPM() {
        let cleaned = rpmDraft.filter { "0123456789".contains($0) }
        guard let value = Double(cleaned) else {
            rpmDraft = String(format: "%.0f", point.rpm)
            return
        }
        fan.updateCurvePoint(id: point.id, rpm: value)
    }

    private func commitAll() {
        commitCelsius()
        commitRPM()
        fan.endSpeedEdit()
    }
}

/// Native NSSlider so dragging stays smooth inside an NSPopover (SwiftUI Slider re-renders every tick).
private struct RPMSlider: NSViewRepresentable {
    var value: Double
    var minValue: Double
    var maxValue: Double
    var onLiveChange: (Double) -> Void
    var onEnded: (Double) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onLiveChange: onLiveChange, onEnded: onEnded)
    }

    func makeNSView(context: Context) -> NSSlider {
        let slider = TrackingSlider()
        slider.minValue = minValue
        slider.maxValue = maxValue
        slider.doubleValue = value
        slider.isContinuous = true
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.onEnded = { [weak coordinator = context.coordinator] value in
            coordinator?.ended(value)
        }
        return slider
    }

    func updateNSView(_ nsView: NSSlider, context: Context) {
        context.coordinator.onLiveChange = onLiveChange
        context.coordinator.onEnded = onEnded
        if nsView.minValue != minValue { nsView.minValue = minValue }
        if nsView.maxValue != maxValue { nsView.maxValue = maxValue }
        if context.coordinator.dragging { return }
        if abs(nsView.doubleValue - value) > 0.5 {
            nsView.doubleValue = value
        }
    }

    final class Coordinator: NSObject {
        var onLiveChange: (Double) -> Void
        var onEnded: (Double) -> Void
        var dragging = false

        init(onLiveChange: @escaping (Double) -> Void, onEnded: @escaping (Double) -> Void) {
            self.onLiveChange = onLiveChange
            self.onEnded = onEnded
        }

        @objc func changed(_ sender: NSSlider) {
            dragging = true
            onLiveChange(sender.doubleValue.rounded())
        }

        func ended(_ value: Double) {
            dragging = false
            onEnded(value.rounded())
        }
    }
}

private final class TrackingSlider: NSSlider {
    var onEnded: ((Double) -> Void)?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        onEnded?(doubleValue)
    }
}

private func formatBytes(_ bytes: UInt64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .memory
    formatter.allowedUnits = [.useMB, .useGB]
    return formatter.string(fromByteCount: Int64(bytes))
}

/// Dev-only: `OneBar snapshot <dir>` renders the real panels into windows and saves PNGs,
/// so layout can be inspected without popping the actual NSPopover.
private enum Snapshotter {
    @MainActor
    static func run(outputDir: String) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let state = AppState()

        func makeWindow(_ view: some View, x: CGFloat) -> NSWindow {
            let window = NSWindow(
                contentRect: NSRect(x: x, y: 200, width: 380, height: 640),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            let host = NSHostingController(rootView: view)
            host.sizingOptions = [.intrinsicContentSize]
            window.contentViewController = host
            window.title = "OneBar Snapshot"
            window.makeKeyAndOrderFront(nil)
            let fitting = host.view.fittingSize
            window.setContentSize(fitting)
            window.setFrameTopLeftPoint(NSPoint(x: x, y: 760))
            return window
        }

        let fanWindow = makeWindow(
            FanPanel().environmentObject(state).environmentObject(state.fan),
            x: 80
        )
        let memoryWindow = makeWindow(
            MemoryPanel().environmentObject(state),
            x: 520
        )
        let clipboardWindow = makeWindow(
            ClipboardRootView()
                .environmentObject(state)
                .environmentObject(state.clipboard),
            x: 960
        )

        // Give the first SMC tick time to fill temps, then walk through modes.
        spin(seconds: 3)
        let dir = URL(fileURLWithPath: outputDir, isDirectory: true)
        capture(fanWindow, to: dir.appendingPathComponent("fan-curve.png"))

        let savedMode = state.fan.mode
        state.fan.curvePoints = (0..<8).map {
            FanCurvePoint(celsius: Double(45 + $0 * 8), rpm: 2000 + Double($0) * 600)
        }
        state.fan.mode = .curve
        spin(seconds: 0.8)
        capture(fanWindow, to: dir.appendingPathComponent("fan-curve-8.png"))

        state.fan.mode = .fixed
        spin(seconds: 0.5)
        capture(fanWindow, to: dir.appendingPathComponent("fan-fixed.png"))

        capture(memoryWindow, to: dir.appendingPathComponent("memory.png"))
        capture(clipboardWindow, to: dir.appendingPathComponent("clipboard.png"))
        state.fan.mode = savedMode
        state.fan.restoreAutoOnQuit()
        return 0
    }

    private static func spin(seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private static func capture(_ window: NSWindow, to url: URL) {
        guard let image = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            CGWindowID(window.windowNumber),
            [.bestResolution]
        ) else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }

    /// Shows the real NSPopover (same embed path as the status bar item) and captures it.
    @MainActor
    static func runPopover(outputDir: String) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let state = AppState()

        let anchorWindow = NSWindow(
            contentRect: NSRect(x: 400, y: 260, width: 320, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let anchor = NSButton(frame: NSRect(x: 24, y: 48, width: 90, height: 28))
        anchor.title = "FAN 62°"
        anchorWindow.contentView?.addSubview(anchor)
        anchorWindow.title = "OneBar Popover Snapshot"
        anchorWindow.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = StatusBarController.makePanelHost(
            FanPanel().environmentObject(state).environmentObject(state.fan)
        )
        if let view = popover.contentViewController?.view {
            let fitting = view.fittingSize
            if fitting.width > 1, fitting.height > 1 { popover.contentSize = fitting }
        }
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        if let window = popover.contentViewController?.view.window {
            window.makeKey()
            window.makeFirstResponder(nil)
        }

        spin(seconds: 3)
        let dir = URL(fileURLWithPath: outputDir, isDirectory: true)
        if let window = popover.contentViewController?.view.window {
            capture(window, to: dir.appendingPathComponent("popover-fan.png"))
        }
        popover.performClose(nil)
        state.fan.restoreAutoOnQuit()
        return 0
    }
}
