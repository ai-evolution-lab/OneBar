import SwiftUI
import AppKit
import Carbon
import Combine

private extension Notification.Name {
    static let clipboardWindowDidShow = Notification.Name("onebar.clipboardWindowDidShow")
}

enum ClipboardFilter: String, CaseIterable, Identifiable {
    case all, text, image, file, favorite
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .text: return "文本"
        case .image: return "图片"
        case .file: return "文件"
        case .favorite: return "收藏"
        }
    }

    var color: Color {
        switch self {
        case .all: return Color(red: 0.95, green: 0.45, blue: 0.70)
        case .text: return Color(red: 0.35, green: 0.78, blue: 0.45)
        case .image: return Color(red: 0.82, green: 0.62, blue: 0.28)
        case .file: return Color(red: 0.40, green: 0.72, blue: 0.78)
        case .favorite: return Color(red: 0.62, green: 0.45, blue: 0.85)
        }
    }

    /// 「图片」含 Finder 复制的图片文件；搜索同时命中正文前缀与图片 OCR 文字。
    func matches(_ item: ClipboardItem, query q: String) -> Bool {
        switch self {
        case .all: break
        case .text: if item.kind != .text { return false }
        case .image: if !item.isImageLike { return false }
        case .file: if item.kind != .file { return false }
        case .favorite: if !item.isFavorite { return false }
        }
        if q.isEmpty { return true }
        if item.preview.localizedCaseInsensitiveContains(q) { return true }
        if item.text?.prefix(5000).localizedCaseInsensitiveContains(q) == true { return true }
        return item.ocrText?.localizedCaseInsensitiveContains(q) ?? false
    }
}

/// 面板的界面状态与动作。刻意不观察 AppState：内存 / 风扇每秒刷新不该波及这张长列表。
@MainActor
final class ClipboardViewModel: ObservableObject {
    struct Actions {
        var hide: @MainActor () -> Void = {}
        var relaunch: @MainActor () -> Void = {}
        var quit: @MainActor () -> Void = {}
    }

    let actions: Actions
    private(set) weak var store: ClipboardStore?

    @Published var filter: ClipboardFilter = .all {
        didSet { if filter != oldValue { recompute() } }
    }
    @Published var query = "" {
        didSet {
            // 清空搜索立即生效，输入中的关键字走防抖
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { applyQuery(query) }
        }
    }
    /// 筛选结果缓存：只在条目 / 筛选 / 防抖后的关键字变化时重算，body 不再全量过滤。
    @Published private(set) var visible: [ClipboardItem] = []
    @Published var selectedID: UUID?
    @Published var previewID: UUID?
    /// 相对时间的基准，面板显示时刷新、显示期间每分钟刷新。
    @Published private(set) var now = Date()

    private var appliedQuery = ""
    private var cancellables = Set<AnyCancellable>()
    private var minuteTimer: Timer?

    init(actions: Actions = Actions()) {
        self.actions = actions
    }

    func attach(_ store: ClipboardStore) {
        guard self.store !== store else { return }
        self.store = store
        cancellables.removeAll()
        // @Published 在 willSet 发值，直接用传入的新数组
        store.$items
            .sink { [weak self] items in self?.recompute(items) }
            .store(in: &cancellables)
        $query
            .removeDuplicates()
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] q in self?.applyQuery(q) }
            .store(in: &cancellables)
    }

    var selectedItem: ClipboardItem? {
        guard let id = selectedID else { return nil }
        return visible.first { $0.id == id }
    }

    var previewItem: ClipboardItem? {
        guard let id = previewID else { return nil }
        return visible.first { $0.id == id } ?? store?.items.first { $0.id == id }
    }

    private func applyQuery(_ raw: String) {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q != appliedQuery else { return }
        appliedQuery = q
        recompute()
    }

    private func recompute(_ items: [ClipboardItem]? = nil) {
        let source = items ?? store?.items ?? []
        let f = filter
        let q = appliedQuery
        visible = source.filter { f.matches($0, query: q) }
        if let id = selectedID, visible.contains(where: { $0.id == id }) { return }
        selectedID = visible.first?.id
    }

    // MARK: 面板生命周期

    func didShow() {
        now = Date()
        selectedID = visible.first?.id
        previewID = nil
        minuteTimer?.invalidate()
        minuteTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.now = Date() }
        }
    }

    func didHide() {
        minuteTimer?.invalidate()
        minuteTimer = nil
        previewID = nil
    }

    // MARK: 行动作

    func select(_ item: ClipboardItem) {
        selectedID = item.id
    }

    /// 复制即完成一次取用，面板随之收起并把焦点交还给原应用，省掉手动关闭。
    func copy(_ item: ClipboardItem) {
        selectedID = item.id
        store?.restore(item)
        actions.hide()
    }

    func copyText(_ item: ClipboardItem) {
        store?.copyRecognizedText(item)
        actions.hide()
    }

    func remove(_ item: ClipboardItem) {
        if selectedID == item.id, let i = visible.firstIndex(where: { $0.id == item.id }) {
            // 删除后选中顺延到下一条，键盘连删不丢焦点
            let next = i + 1 < visible.count ? visible[i + 1] : (i > 0 ? visible[i - 1] : nil)
            selectedID = next?.id
        }
        if previewID == item.id { previewID = nil }
        store?.remove(item)
    }

    func toggleFavorite(_ item: ClipboardItem) {
        store?.toggleFavorite(item)
    }

    func preview(_ item: ClipboardItem) {
        guard item.isImageLike else { return }
        selectedID = item.id
        previewID = item.id
    }

    func closePreview() {
        previewID = nil
    }

    // MARK: 键盘

    func moveSelection(_ delta: Int) {
        guard !visible.isEmpty else { return }
        let current = selectedID.flatMap { id in visible.firstIndex { $0.id == id } }
        let target = current.map { min(max($0 + delta, 0), visible.count - 1) } ?? 0
        let item = visible[target]
        selectedID = item.id
        if previewID != nil { previewID = item.isImageLike ? item.id : nil }
    }

    func copySelected() -> Bool {
        guard let item = selectedItem else { return false }
        copy(item)
        return true
    }

    func deleteSelected() -> Bool {
        guard let item = selectedItem else { return false }
        remove(item)
        return true
    }

    func togglePreviewSelected() -> Bool {
        if previewID != nil {
            previewID = nil
            return true
        }
        guard let item = selectedItem, item.isImageLike else { return false }
        preview(item)
        return true
    }
}

struct ClipboardRootView: View {
    @EnvironmentObject private var clipboard: ClipboardStore
    @StateObject private var fallback = ClipboardViewModel()
    private let injected: ClipboardViewModel?

    /// 正式面板由窗口控制器注入模型；不传时（截图自测）自建一个无动作模型。
    init(model: ClipboardViewModel? = nil) {
        injected = model
    }

    var body: some View {
        let model = injected ?? fallback
        ClipboardPanel(model: model)
            .onAppear { model.attach(clipboard) }
    }
}

private struct ClipboardPanel: View {
    @ObservedObject var model: ClipboardViewModel

    var body: some View {
        let items = model.visible
        let now = model.now
        let selectedID = model.selectedID
        VStack(spacing: 0) {
            ClipboardHeader(model: model)
            Divider().opacity(0.25)
            if items.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    List(Array(items.enumerated()), id: \.element.id) { index, item in
                        ClipboardRow(
                            index: index + 1,
                            item: item,
                            selected: selectedID == item.id,
                            timeText: item.timeLabel(now: now),
                            model: model
                        )
                        .equatable()
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .id(item.id)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .onChange(of: model.selectedID) { _, id in
                        // 键盘移动时把选中行滚进可见区（已可见则不动）
                        guard let id else { return }
                        proxy.scrollTo(id)
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .clipboardWindowDidShow)) { _ in
                        guard let first = model.visible.first?.id else { return }
                        proxy.scrollTo(first, anchor: .top)
                    }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 560)
        .background(Color(red: 0.12, green: 0.12, blue: 0.13))
        .overlay {
            if let item = model.previewItem, let path = item.imageSourcePath {
                ImagePreviewOverlay(item: item, path: path, model: model)
            }
        }
        .preferredColorScheme(.dark)
        .onExitCommand {
            if model.previewID != nil {
                model.closePreview()
            } else {
                model.actions.hide()
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("还没有记录")
                .foregroundStyle(.secondary)
            Text("复制文字、图片或文件后会出现在这里。")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(WindowDragArea())
    }
}

private struct ClipboardHeader: View {
    @EnvironmentObject var clipboard: ClipboardStore
    @ObservedObject var model: ClipboardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("剪贴板")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Spacer()
                Button {
                    clipboard.beginRecordHotKey()
                } label: {
                    Text(clipboard.recordingHotKey ? "按下快捷键…" : clipboard.hotKey.display)
                        .font(.caption.monospaced())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("点击后按下新的快捷键")
                Menu {
                    Picker("保留策略", selection: Binding(
                        get: { clipboard.retention },
                        set: { clipboard.setRetention($0) }
                    )) {
                        ForEach(RetentionPolicy.allCases) { policy in
                            Text(policy.title).tag(policy)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(clipboard.retention.title)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.08), in: Capsule())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("历史保留时长，收藏条目不会过期")
                Button("清空") { clipboard.clear() }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Menu {
                    Button("重新启动") { model.actions.relaunch() }
                    Button("退出 OneBar", role: .destructive) { model.actions.quit() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 16, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help("重新启动或退出")
            }
            HStack(spacing: 6) {
                ForEach(ClipboardFilter.allCases) { item in
                    Button {
                        model.filter = item
                    } label: {
                        Text(item.title)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(model.filter == item ? item.color : item.color.opacity(0.28), in: Capsule())
                            .foregroundStyle(model.filter == item ? Color.black : Color.white.opacity(0.9))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("搜索（含图片文字）", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.callout)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.white.opacity(0.06))
            )
            if let notice = clipboard.notice {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(WindowDragArea())
    }
}

/// 行视图按显示内容判等：无关的父视图刷新（选中别的行、搜索框输入）不再重绘整屏行。
private struct ClipboardRow: View, Equatable {
    let index: Int
    let item: ClipboardItem
    let selected: Bool
    let timeText: String
    let model: ClipboardViewModel
    @State private var hovered = false

    nonisolated static func == (lhs: ClipboardRow, rhs: ClipboardRow) -> Bool {
        let a = lhs.item, b = rhs.item
        return lhs.index == rhs.index
            && lhs.selected == rhs.selected
            && lhs.timeText == rhs.timeText
            && a.id == b.id
            && a.isFavorite == b.isFavorite
            && a.thumbPath == b.thumbPath
            && a.imagePath == b.imagePath
            && a.preview == b.preview
            && a.byteCount == b.byteCount
            && a.charCount == b.charCount
            && a.pixelWidth == b.pixelWidth
            && a.pixelHeight == b.pixelHeight
            && (a.recognizedText == nil) == (b.recognizedText == nil)
    }

    var body: some View {
        let actionsVisible = selected || hovered
        HStack(alignment: .top, spacing: 10) {
            Text("\(index)")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(.white.opacity(0.22))
                .frame(width: 38, alignment: .trailing)
            Button { model.copy(item) } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Color.accentColor, in: Circle())
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
            .help("复制到剪贴板并关闭面板（↩）")

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(item.kind.title)
                        .font(.caption.weight(.semibold))
                    Text(item.sizeLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(timeText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    // 常驻布局、仅切透明度：滚动时鼠标扫过不再触发行内增删导致的重排抖动
                    HStack(spacing: 10) {
                        if item.recognizedText != nil {
                            Button { model.copyText(item) } label: {
                                Image(systemName: "text.viewfinder")
                            }
                            .buttonStyle(.plain)
                            .help("复制图片中的文字")
                        }
                        if item.isImageLike {
                            Button { model.preview(item) } label: {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                            }
                            .buttonStyle(.plain)
                            .help("查看大图（空格）")
                        }
                        Button { model.remove(item) } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                        .help("删除（⌘⌫）")
                        Button { model.toggleFavorite(item) } label: {
                            Image(systemName: item.isFavorite ? "star.fill" : "star")
                                .foregroundStyle(item.isFavorite ? .yellow : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .opacity(actionsVisible ? 1 : 0)
                    .allowsHitTesting(actionsVisible)
                    Button { model.copy(item) } label: {
                        Image(systemName: "square.on.square")
                            .foregroundStyle(Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("复制到剪贴板并关闭面板")
                }
                if let path = item.previewSourcePath {
                    ThumbnailView(path: path)
                        .contentShape(Rectangle())
                        .onTapGesture { model.copy(item) }
                        .onDrag { dragProvider() }
                } else if item.kind == .text {
                    Text(item.displayText)
                        .font(.callout)
                        .lineLimit(3)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { model.copy(item) }
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "doc")
                        Text(item.preview)
                            .lineLimit(2)
                    }
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { model.copy(item) }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            selected ? Color.white.opacity(0.10) : hovered ? Color.white.opacity(0.05) : Color.clear,
            in: RoundedRectangle(cornerRadius: 10)
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture { model.select(item) }
        .onHover { hovered = $0 }
    }

    /// 拖出图片原件（剪贴板图片即本地 PNG，Finder 图片即原文件）。
    private func dragProvider() -> NSItemProvider {
        guard let path = item.imageSourcePath else { return NSItemProvider() }
        let url = URL(fileURLWithPath: path)
        return NSItemProvider(contentsOf: url) ?? NSItemProvider(object: url as NSURL)
    }
}

/// 窗口内大图预览：点背景 / 空格 / Esc 关闭，↑↓ 切换相邻图片。
private struct ImagePreviewOverlay: View {
    let item: ClipboardItem
    let path: String
    let model: ClipboardViewModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.88)
                .contentShape(Rectangle())
                .onTapGesture { model.closePreview() }
            VStack(spacing: 10) {
                ThumbnailView(path: path, maxPixel: 1600, height: nil)
                    .id(path)
                    .onDrag {
                        let url = URL(fileURLWithPath: path)
                        return NSItemProvider(contentsOf: url) ?? NSItemProvider(object: url as NSURL)
                    }
                HStack(spacing: 10) {
                    Text(item.sizeLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if item.kind == .file {
                        Text(item.preview)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else if item.ocrText == nil {
                        Text("文字识别中…")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if item.recognizedText != nil {
                        Button("复制文字") { model.copyText(item) }
                    }
                    Button("复制图片") { model.copy(item) }
                    Button("关闭") { model.closePreview() }
                }
                .controlSize(.small)
            }
            .padding(16)
        }
    }
}

private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowDragNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class WindowDragNSView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

@MainActor
final class ClipboardWindowController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let host: NSHostingController<AnyView>
    private let model: ClipboardViewModel
    private var keyMonitor: Any?
    /// 面板是靠激活 OneBar 显示出来的；记下当时的前台应用，收起时把焦点还回去。
    private var previousApp: NSRunningApplication?

    init(state: AppState) {
        // 只持有动作闭包，不观察 AppState，避免每秒的状态刷新重算列表
        let model = ClipboardViewModel(actions: .init(
            hide: { [weak state] in state?.hideClipboard() },
            relaunch: { [weak state] in state?.relaunch() },
            quit: { [weak state] in state?.quit() }
        ))
        model.attach(state.clipboard)
        self.model = model
        let root = ClipboardRootView(model: model)
            .environmentObject(state.clipboard)
        host = NSHostingController(rootView: AnyView(root))
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 640),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.title = "剪贴板"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.contentViewController = host
        panel.appearance = NSAppearance(named: .darkAqua)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event)
        }
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        if panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        rememberFrontmostApp()
        centerOnScreen()
        model.didShow()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .clipboardWindowDidShow, object: nil)
    }

    func hide() {
        guard panel.isVisible else { return }
        model.didHide()
        panel.orderOut(nil)
        restoreFrontmostApp()
    }

    /// ↑↓ 移动选中，↩ 复制并收起，空格大图预览，⌘⌫ 删除，Esc 先关预览。
    /// 搜索框有内容时空格 / ⌘⌫ 留给输入；输入法组字中一律放行。
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard event.window === panel, panel.isKeyWindow else { return event }
        if model.store?.recordingHotKey == true { return event }
        let editor = panel.firstResponder as? NSTextView
        if editor?.hasMarkedText() == true { return event }
        let fieldEmpty = editor?.string.isEmpty ?? true
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch Int(event.keyCode) {
        case kVK_DownArrow where flags.isEmpty:
            model.moveSelection(1)
            return nil
        case kVK_UpArrow where flags.isEmpty:
            model.moveSelection(-1)
            return nil
        case kVK_Return where flags.isEmpty, kVK_ANSI_KeypadEnter where flags.isEmpty:
            return model.copySelected() ? nil : event
        case kVK_Space where flags.isEmpty:
            if model.previewID != nil || fieldEmpty {
                return model.togglePreviewSelected() ? nil : event
            }
            return event
        case kVK_Delete where flags == .command:
            guard fieldEmpty else { return event }
            return model.deleteSelected() ? nil : event
        case kVK_Escape where model.previewID != nil:
            model.closePreview()
            return nil
        default:
            return event
        }
    }

    private func rememberFrontmostApp() {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        previousApp = front
    }

    private func restoreFrontmostApp() {
        guard let app = previousApp, !app.isTerminated else { return }
        previousApp = nil
        app.activate(from: .current, options: [])
    }

    private func centerOnScreen() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else {
            panel.center()
            return
        }
        let size = panel.frame.size
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        )
        panel.setFrameOrigin(origin)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }
}
