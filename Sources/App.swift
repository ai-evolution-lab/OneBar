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
                Button("退出") { state.quit() }
            }
            .font(.caption)
        }
        .padding(14)
        .frame(width: 320)
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
                Spacer()
                Text("压力 \(mem.pressure.title)")
                    .foregroundStyle(mem.pressure == .normal ? Color.secondary : Color.orange)
            }
            row("已用", bytes: mem.usedBytes, total: mem.totalBytes)
            row("应用", bytes: mem.appBytes)
            row("已联动", bytes: mem.wiredBytes)
            row("压缩", bytes: mem.compressedBytes)
            row("交换", bytes: mem.swapUsedBytes)
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
        .foregroundStyle(.secondary)
    }
}

private struct FanPanel: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var fan: FanController

    var body: some View {
        PanelChrome(title: "风扇") {
            if let error = fan.errorMessage {
                Text(error).foregroundStyle(.red).font(.callout)
            } else {
                HStack {
                    Text(fan.cpuTemp.map { String(format: "CPU %.0f°C", $0) } ?? "CPU --")
                    Spacer()
                    Text(fan.hottestTemp.map { String(format: "最高 %.0f°C", $0) } ?? "")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)

                ForEach(fan.fans) { item in
                    HStack {
                        Text("风扇 \(item.id)")
                        Spacer()
                        Text(String(format: "%.0f  (%.0f–%.0f)", item.actualRPM, item.minRPM, item.maxRPM))
                            .font(.system(.callout, design: .monospaced))
                    }
                }

                Picker("策略", selection: Binding(
                    get: { fan.mode },
                    set: { newValue in
                        if newValue == .auto { fan.selectAuto() } else { fan.selectFixed() }
                    }
                )) {
                    Text("自动").tag(FanMode.auto)
                    Text("固定转速").tag(FanMode.fixed)
                }
                .pickerStyle(.segmented)

                if fan.mode == .fixed {
                    HStack {
                        Slider(
                            value: Binding(
                                get: { fan.fixedRPM },
                                set: { fan.fixedRPM = $0 }
                            ),
                            in: fan.sliderMin...max(fan.sliderMax, fan.sliderMin + 1),
                            step: 50
                        ) { editing in
                            if !editing { fan.applyFixed() }
                        }
                        TextField("", value: $fan.fixedRPM, format: .number.precision(.fractionLength(0)))
                            .frame(width: 64)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { fan.applyFixed() }
                    }
                    Text("两颗风扇共用这个目标，超出各自上下限时自动钳位。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if fan.applying {
                    Text("正在写入…").font(.caption).foregroundStyle(.secondary)
                }
                if fan.passwordless {
                    Text("已授权，切换自动/固定不再要密码。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Button("授权风扇控制（仅一次）") { fan.authorize() }
                    Text("第一次输入密码后写入系统授权，之后切换都不再弹窗。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let other = fan.competitor {
                    Text("\(other) 正在运行，会抢风扇控制，请先退出它。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if fan.needsAdmin {
                    Text("授权失败，请再点一次「授权风扇控制」。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}

private func formatBytes(_ bytes: UInt64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .memory
    formatter.allowedUnits = [.useMB, .useGB]
    return formatter.string(fromByteCount: Int64(bytes))
}
