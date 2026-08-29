import SwiftUI
import AppKit

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
}

struct ClipboardRootView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var clipboard: ClipboardStore
    @State private var filter: ClipboardFilter = .all
    @State private var query = ""
    @State private var selectedID: UUID?

    var body: some View {
        let items = filtered
        VStack(spacing: 0) {
            header
            Divider().opacity(0.25)
            if items.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    List(Array(items.enumerated()), id: \.element.id) { index, item in
                        ClipboardRow(
                            index: index + 1,
                            item: item,
                            selected: selectedID == item.id
                        ) {
                            selectedID = item.id
                            clipboard.restore(item)
                            state.hideClipboard()
                        } onCopy: {
                            clipboard.restore(item)
                        } onDelete: {
                            clipboard.remove(item)
                        } onFavorite: {
                            clipboard.toggleFavorite(item)
                        }
                        .onTapGesture {
                            selectedID = item.id
                        }
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .id(item.id)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .onReceive(NotificationCenter.default.publisher(for: .clipboardWindowDidShow)) { _ in
                        guard let first = filtered.first?.id else { return }
                        selectedID = first
                        proxy.scrollTo(first, anchor: .top)
                    }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 560)
        .background(Color(red: 0.12, green: 0.12, blue: 0.13))
        .preferredColorScheme(.dark)
        .onAppear {
            if selectedID == nil { selectedID = filtered.first?.id }
        }
        .onExitCommand {
            state.hideClipboard()
        }
    }

    private var header: some View {
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
            }
            HStack(spacing: 6) {
                ForEach(ClipboardFilter.allCases) { item in
                    Button {
                        filter = item
                    } label: {
                        Text(item.title)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(filter == item ? item.color : item.color.opacity(0.28), in: Capsule())
                            .foregroundStyle(filter == item ? Color.black : Color.white.opacity(0.9))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("搜索", text: $query)
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
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(WindowDragArea())
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

    private var filtered: [ClipboardItem] {
        clipboard.items.filter { item in
            switch filter {
            case .all: break
            case .text: if item.kind != .text { return false }
            case .image: if item.kind != .image { return false }
            case .file: if item.kind != .file { return false }
            case .favorite: if !item.isFavorite { return false }
            }
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if q.isEmpty { return true }
            return item.preview.localizedCaseInsensitiveContains(q)
                || (item.text?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }
}

private struct ClipboardRow: View {
    let index: Int
    let item: ClipboardItem
    let selected: Bool
    let onRestore: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void
    let onFavorite: () -> Void
    @State private var hovered = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(index)")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(.white.opacity(0.22))
                .frame(width: 38, alignment: .trailing)
            Button(action: onRestore) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Color.accentColor, in: Circle())
            }
            .buttonStyle(.plain)
            .padding(.top, 4)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(item.kind.title)
                        .font(.caption.weight(.semibold))
                    Text(item.sizeLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(item.timeLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if selected || hovered {
                        Button(action: onDelete) {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                        Button(action: onFavorite) {
                            Image(systemName: item.isFavorite ? "star.fill" : "star")
                                .foregroundStyle(item.isFavorite ? .yellow : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    Button {
                        onCopy()
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            copied = false
                        }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "square.on.square")
                            .foregroundStyle(copied ? Color.green : Color.secondary)
                            .scaleEffect(copied ? 1.15 : 1.0)
                    }
                    .buttonStyle(.plain)
                    .animation(.easeInOut(duration: 0.15), value: copied)
                    .help("复制到剪贴板")
                }
                if let path = item.previewSourcePath {
                    ThumbnailView(path: path)
                } else if item.kind == .text {
                    Text(item.text ?? item.preview)
                        .font(.callout)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "doc")
                        Text(item.preview)
                            .lineLimit(2)
                    }
                    .font(.callout)
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
        .onHover { hovered = $0 }
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

    init(state: AppState) {
        let root = ClipboardRootView()
            .environmentObject(state)
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
        centerOnScreen()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .clipboardWindowDidShow, object: nil)
    }

    func hide() {
        panel.orderOut(nil)
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
