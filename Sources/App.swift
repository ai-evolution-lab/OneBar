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
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.intrinsicContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = false
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
        button.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var memory = MemorySnapshot.zero
    @Published var launchAtLogin: Bool
    let clipboard = ClipboardStore()
    let fan = FanController()
    weak var clipboardWindow: ClipboardWindowController?

    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

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
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.memory = MemorySampler.sample()
            }
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
    let title: String
    @ViewBuilder var content: Content
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            content
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
        }
        .padding(14)
        .frame(width: 340)
    }
}

private struct MemoryPanel: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        PanelChrome(title: "内存") {
            let mem = state.memory
            HStack(alignment: .firstTextBaseline) {
                Text(String(format: "%.0f%%", mem.usedPercent))
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Spacer()
                Label(mem.pressure.title, systemImage: mem.pressure == .normal ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(mem.pressure == .normal ? Color.secondary : Color.orange)
            }
            VStack(spacing: 5) {
                row("已用", bytes: mem.usedBytes, total: mem.totalBytes)
                row("应用", bytes: mem.appBytes)
                row("已联动", bytes: mem.wiredBytes)
                row("压缩", bytes: mem.compressedBytes)
                row("交换", bytes: mem.swapUsedBytes)
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 11)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        }
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
    }
}

private struct FanPanel: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var fan: FanController

    var body: some View {
        PanelChrome(title: "风扇") {
            if let error = fan.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    tempHeader
                    fanCard
                    strategyPicker
                    modeControls
                    statusFootnotes
                }
            }
        }
    }

    private var tempHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(fan.cpuTemp.map { String(format: "%.0f", $0) } ?? "--")
                .font(.system(size: 32, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text("°C")
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            Text("CPU")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(fan.hottestTemp.map { String(format: "最高 %.0f°C", $0) } ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var fanCard: some View {
        VStack(spacing: 6) {
            ForEach(fan.fans) { item in
                HStack(spacing: 10) {
                    Circle()
                        .fill(item.isManual ? Color.accentColor : Color.secondary.opacity(0.35))
                        .frame(width: 7, height: 7)
                    Text("风扇 \(item.id)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.0f", item.actualRPM))
                        .font(.system(.body, design: .monospaced).weight(.medium))
                        .frame(width: 54, alignment: .trailing)
                    Text(String(format: "%.0f–%.0f", item.minRPM, item.maxRPM))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 92, alignment: .trailing)
                }
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 11)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
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
                    .font(.system(.callout, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 60)
                    .textFieldStyle(.roundedBorder)
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
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 6) {
                ForEach(fan.curvePoints.sorted(by: { $0.celsius < $1.celsius })) { point in
                    CurveRow(fan: fan, point: point)
                }
            }
            .padding(.vertical, 4)
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
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
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
        HStack(spacing: 4) {
            Text("≥")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 12)
            TextField("", text: $celsiusDraft)
                .font(.system(.callout, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .frame(width: 42)
                .focused($focusedField, equals: .celsius)
                .onSubmit { commitCelsius() }
            Text("°C")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .leading)
            Text("→")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .frame(width: 12)
            TextField("", text: $rpmDraft)
                .font(.system(.callout, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .frame(width: 58)
                .focused($focusedField, equals: .rpm)
                .onSubmit { commitRPM() }
            Text("RPM")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .leading)
            Spacer(minLength: 4)
            Button {
                fan.removeCurvePoint(point.id)
            } label: {
                Image(systemName: "minus.circle.fill")
            }
            .buttonStyle(.plain)
            .disabled(fan.curvePoints.count <= 1)
            .foregroundStyle(
                fan.curvePoints.count <= 1
                    ? Color.secondary.opacity(0.3)
                    : Color.secondary.opacity(0.7)
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
