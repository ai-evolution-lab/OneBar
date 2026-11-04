import AppKit
import ApplicationServices
import SwiftUI

/// Preferences are keyed by bundle ID, so a PID change or app restart keeps the selection.
struct MenuBarSelection {
    static let key = "menuBar.hiddenBundles"
    static let ownBundle = "com.lizhiwei.OneBar"
    var hidden: Set<String>

    init(defaults: UserDefaults = .standard) {
        hidden = Set(defaults.stringArray(forKey: Self.key) ?? [])
        hidden = hidden.filter { Self.canHide($0) }
    }

    static func canHide(_ bundle: String) -> Bool {
        !bundle.isEmpty && bundle != ownBundle && !bundle.hasPrefix("com.apple.")
    }

    mutating func setVisible(_ visible: Bool, bundle: String, defaults: UserDefaults = .standard) {
        guard Self.canHide(bundle) else { return }
        if visible { hidden.remove(bundle) } else { hidden.insert(bundle) }
        defaults.set(hidden.sorted(), forKey: Self.key)
    }

    func allowedBundles(running: Set<String>) -> [String] {
        running.subtracting(hidden).union([
            Self.ownBundle, "com.apple.MenuBarAgent", "com.apple.controlcenter", "com.apple.systemuiserver",
        ]).sorted()
    }
}

@MainActor
final class MenuBarController: NSObject, ObservableObject {
    struct Row: Identifiable {
        let id: String
        let name: String
        let icon: NSImage?
        let count: Int
        let running: Bool
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var selection = MenuBarSelection()
    @Published private(set) var authorized = AXIsProcessTrusted()
    @Published private(set) var refreshing = false
    @Published private(set) var applying = false
    @Published private(set) var error: String?
    let available = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 && OBMenuBarVisibilityAvailable()

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var assertion: Any?
    private var appliedBundles: [String]?
    private var generation = 0
    private var stopped = false
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var knownNames = UserDefaults.standard.dictionary(forKey: "menuBar.appNames") as? [String: String] ?? [:]

    override init() {
        super.init()
        item.autosaveName = "OneBar.MenuBarOrganizer"
        item.button?.image = NSImage(systemSymbolName: "tray", accessibilityDescription: "菜单栏收纳")
        item.button?.toolTip = "菜单栏收纳：选择常驻显示的应用"
        item.button?.target = self
        item.button?.action = #selector(toggle)
        popover.contentViewController = StatusBarController.makePanelHost(MenuBarPanel().environmentObject(self))
        popover.behavior = .transient
        popover.animates = false
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didWakeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    if name == NSWorkspace.didWakeNotification { self?.releaseAssertion() }
                    self?.applySelection()
                    self?.refresh()
                }
            })
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.stopped else { return }
                self.refresh()
                self.applySelection()
            }
        }
        applySelection()
        refresh()
    }

    @objc func toggle() {
        if popover.isShown { popover.performClose(nil); return }
        refresh()
        guard let button = item.button else { return }
        syncPopoverSize()
        button.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func syncPopoverSize() {
        guard let view = popover.contentViewController?.view else { return }
        let size = view.fittingSize
        if size.width > 1, size.height > 1 { popover.contentSize = size }
    }

    func requestAuthorization() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func setVisible(_ visible: Bool, bundle: String) {
        error = nil
        selection.setVisible(visible, bundle: bundle)
        UserDefaults.standard.set(knownNames, forKey: "menuBar.appNames")
        applySelection()
    }

    func showAll() {
        for bundle in selection.hidden { selection.setVisible(true, bundle: bundle) }
        applySelection()
        refresh()
    }

    func stop() {
        stopped = true
        timer?.invalidate()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        popover.performClose(nil)
        releaseAssertion()
    }

    private func releaseAssertion() {
        generation += 1
        OBMenuBarInvalidate(assertion)
        assertion = nil
        appliedBundles = nil
        applying = false
    }

    private func applySelection() {
        guard !stopped else { return }
        guard !selection.hidden.isEmpty else {
            releaseAssertion()
            error = nil
            return
        }
        guard error == nil else { return } // Retry on an explicit selection change, not every timer tick.
        guard available else {
            releaseAssertion()
            error = "收纳未生效：需要支持此接口的 macOS 27 或更高版本。"
            return
        }
        // MenuBarAgent only resolves allowed app bundles installed in /Applications.
        guard Bundle.main.bundleURL.standardizedFileURL.path.hasPrefix("/Applications/") else {
            releaseAssertion()
            error = "收纳未生效：请从 /Applications 中运行 OneBar。"
            return
        }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let bundles = selection.allowedBundles(running: running)
        guard bundles != appliedBundles || assertion == nil else { return }
        guard !applying else { return } // Completion rechecks the latest selection.
        generation += 1
        let current = generation
        applying = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.applying, self.generation == current else { return }
            self.releaseAssertion()
            self.error = "收纳未生效：系统响应超时，已恢复全部显示。请重新勾选后重试。"
        }
        OBMenuBarActivate(bundles) { [weak self] next, reason in
            guard let self, !self.stopped, self.generation == current else {
                OBMenuBarInvalidate(next)
                return
            }
            self.applying = false
            guard let next, reason == nil else {
                self.releaseAssertion()
                self.error = "收纳未生效，已恢复全部显示。\(reason ?? "系统没有接受配置。")"
                return
            }
            let old = self.assertion
            self.assertion = next
            self.appliedBundles = bundles
            self.error = nil
            OBMenuBarInvalidate(old)
            self.applySelection()
        }
    }

    func refresh() {
        guard !stopped else { return }
        authorized = AXIsProcessTrusted()
        guard authorized, !refreshing else { return }
        refreshing = true
        let apps = NSWorkspace.shared.runningApplications.filter {
            guard let id = $0.bundleIdentifier else { return false }
            return MenuBarSelection.canHide(id) && $0.bundleURL?.pathExtension == "app"
        }
        // AX IPC must not run on the main thread: an unresponsive app may time out.
        DispatchQueue.global(qos: .utility).async {
            var found: [String: (String, NSImage?, Int)] = [:]
            for app in apps {
                let element = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(element, 0.1)
                var bar: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, "AXExtrasMenuBar" as CFString, &bar) == .success,
                      let bar, CFGetTypeID(bar) == AXUIElementGetTypeID() else { continue }
                var children: CFTypeRef?
                guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children) == .success,
                      let items = children as? [AXUIElement], !items.isEmpty,
                      let id = app.bundleIdentifier else { continue }
                let prior = found[id]?.2 ?? 0
                found[id] = (app.localizedName ?? id, app.icon, prior + items.count)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.stopped else { return }
                var rows = found.map { id, value in
                    Row(id: id, name: value.0, icon: value.1, count: value.2, running: true)
                }
                for row in rows { self.knownNames[row.id] = row.name }
                for id in self.selection.hidden where found[id] == nil {
                    rows.append(Row(id: id, name: self.knownNames[id] ?? id, icon: nil, count: 0, running: false))
                }
                self.rows = rows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                self.refreshing = false
                DispatchQueue.main.async { [weak self] in self?.syncPopoverSize() }
            }
        }
    }
}

private struct MenuBarPanel: View {
    @EnvironmentObject var organizer: MenuBarController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("菜单栏收纳").font(.headline)
            Text("勾选常驻显示的应用，其余收纳。选择自动保存。")
                .font(.callout).foregroundStyle(.secondary)
            if !organizer.available {
                Text("此系统暂不支持逐应用收纳，需要 macOS 27 的菜单栏接口。")
                    .font(.callout).foregroundStyle(.orange)
            } else if !organizer.authorized {
                Text("需要辅助功能权限，以读取实际的菜单栏图标。授权后列表会自动更新。")
                    .font(.callout)
                Button("打开辅助功能授权") { organizer.requestAuthorization() }
            } else {
                let active = organizer.rows.filter(\.running)
                let visible = active.filter { !organizer.selection.hidden.contains($0.id) }.count
                HStack {
                    Text("常驻 \(visible) / \(active.count) 个应用").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if organizer.refreshing || organizer.applying { ProgressView().controlSize(.small) }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(organizer.rows) { row in
                            Toggle(isOn: Binding(
                                get: { !organizer.selection.hidden.contains(row.id) },
                                set: { organizer.setVisible($0, bundle: row.id) }
                            )) {
                                HStack(spacing: 8) {
                                    if let icon = row.icon {
                                        Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                                    }
                                    Text(row.name).lineLimit(1)
                                    Spacer()
                                    if !row.running {
                                        Text("未检测到图标").font(.caption).foregroundStyle(.secondary)
                                    } else if row.count > 1 {
                                        Text("\(row.count) 个图标").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                        if organizer.rows.isEmpty {
                            Text(organizer.refreshing ? "正在读取菜单栏图标…" : "尚未检测到第三方菜单栏图标，点击刷新重试。")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }.padding(2)
                }
                .frame(height: min(300, max(60, CGFloat(organizer.rows.count) * 32)))
            }
            if let error = organizer.error {
                Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Text("按应用收纳：同一应用的多个图标一起切换。OneBar 入口和系统图标始终保留，新应用默认显示。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("全部显示") { organizer.showAll() }
                Spacer()
                Button("刷新列表") { organizer.refresh() }.disabled(organizer.refreshing)
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}
