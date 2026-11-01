import AppKit
import Foundation
import Carbon

/// Clipboard history adapted from Maccy (MIT): poll NSPasteboard.changeCount.
struct ClipboardItem: Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case text
        case image
        case file

        var title: String {
            switch self {
            case .text: return "文本"
            case .image: return "图片"
            case .file: return "文件"
            }
        }
    }

    var id: UUID
    var kind: Kind
    var createdAt: Date
    var preview: String
    var text: String?
    var imagePath: String?
    var filePaths: [String]
    var byteCount: Int64
    var isFavorite: Bool
    var thumbPath: String?
    var charCount: Int
    /// 去重用内容哈希：文本按 UTF-8、图片按落盘字节、文件按路径列表。旧数据缺失时启动后补算。
    var contentHash: String? = nil
    /// 像素尺寸；0 表示读取失败，nil 表示尚未读取。
    var pixelWidth: Int? = nil
    var pixelHeight: Int? = nil
    /// OCR 结果：nil 尚未识别，空串表示识别过但没有文字。
    var ocrText: String? = nil

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM月dd日"
        return formatter
    }()

    /// 渲染路径专用的有界预览：长文本只取前缀，避免 Text 排版 / count 全文遍历拖垮滚动。
    var displayText: String {
        guard let text else { return preview }
        return String(text.prefix(300))
    }

    var previewSourcePath: String? {
        if let thumbPath { return thumbPath }
        return imageSourcePath
    }

    /// 图片原件：剪贴板图片取落盘文件，Finder 复制的图片文件取第一个路径。
    var imageSourcePath: String? {
        if kind == .image { return imagePath }
        if kind == .file, let path = filePaths.first, ClipboardItem.isImageFile(path) { return path }
        return nil
    }

    /// 「图片」筛选口径：剪贴板图片 + Finder 复制的图片文件。
    var isImageLike: Bool { imageSourcePath != nil }

    var pixelLabel: String? {
        guard let w = pixelWidth, let h = pixelHeight, w > 0, h > 0 else { return nil }
        return "\(w)×\(h)"
    }

    var recognizedText: String? {
        guard let ocrText, !ocrText.isEmpty else { return nil }
        return ocrText
    }

    var sizeLabel: String {
        switch kind {
        case .text:
            return "\(charCount) 个字符"
        case .image, .file:
            let bytes = ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
            if let pixels = pixelLabel { return "\(pixels) · \(bytes)" }
            return bytes
        }
    }

    var timeLabel: String { timeLabel(now: Date()) }

    func timeLabel(now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(createdAt) / 60)
        if minutes < 1 { return "刚刚" }
        if minutes < 60 { return "\(minutes) 分钟前" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) 小时前" }
        return Self.dateFormatter.string(from: createdAt)
    }

    static func isImageFile(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "webp", "tif", "tiff", "heic", "bmp"].contains(ext)
    }
}

/// 保留策略：按时间清理历史，收藏条目豁免。
enum RetentionPolicy: String, CaseIterable, Identifiable {
    case today, oneMonth, threeMonths, halfYear, forever
    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return "仅保留当天"
        case .oneMonth: return "保留 1 个月"
        case .threeMonths: return "保留 3 个月"
        case .halfYear: return "保留半年"
        case .forever: return "永久保留"
        }
    }

    var cutoff: Date? {
        let calendar = Calendar.current
        let now = Date()
        switch self {
        case .today: return calendar.startOfDay(for: now)
        case .oneMonth: return calendar.date(byAdding: .day, value: -30, to: now)
        case .threeMonths: return calendar.date(byAdding: .day, value: -90, to: now)
        case .halfYear: return calendar.date(byAdding: .day, value: -180, to: now)
        case .forever: return nil
        }
    }
}

/// 图片还原时 TIFF 按需生成：大图转 TIFF 要几十毫秒，只有对方应用真要 TIFF 时才付这笔账。
private final class TIFFProvider: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    private let path: String

    init(path: String) { self.path = path }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .tiff, let data = ClipboardMedia.tiffData(fromFile: path) else { return }
        item.setData(data, forType: .tiff)
    }
}

@MainActor
final class ClipboardStore: ObservableObject {
    @Published var items: [ClipboardItem] = []
    @Published var hotKey: HotKeySpec
    @Published var recordingHotKey = false
    @Published var retention: RetentionPolicy
    /// 一次性提示（如超大图片未保存），几秒后自动清空。
    @Published private(set) var notice: String?
    /// false 时停止轮询、清理与快捷键，见 `setActive(_:)`。
    @Published private(set) var isActive = true

    private let pasteboard: NSPasteboard
    private var changeCount: Int
    private var ignoreUntilCount: Int?
    private var timer: Timer?
    private var cleanupTimer: Timer?
    private var keyMonitor: Any?
    private var tiffProvider: TIFFProvider?
    private var noticeTask: Task<Void, Never>?
    private var ocrRunning = false
    /// 历史索引是否成功读入（或本就不存在）；孤儿清理以此为前提。
    private var indexLoaded = false
    private let root: URL
    private let imagesDir: URL
    private let thumbsDir: URL
    private let indexURL: URL

    private let ignoredTypes: Set<String> = [
        "org.nspasteboard.TransientType",
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.AutoGeneratedType",
        "com.agilebits.onepassword",
        "com.typeit4me.clipping",
        "de.petermaurer.TransientPasteboardType"
    ]

    private let persistQueue = DispatchQueue(label: "onebar.clip.persist", qos: .utility)
    private let captureQueue = DispatchQueue(label: "onebar.clip.capture", qos: .userInitiated)
    private let metaQueue = DispatchQueue(label: "onebar.clip.meta", qos: .utility)
    private let ocrQueue = DispatchQueue(label: "onebar.clip.ocr", qos: .background)

    /// `rootDirectory` / `pasteboard` 仅供自测注入，默认即真实数据目录与系统剪贴板。
    init(rootDirectory: URL? = nil, pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        changeCount = pasteboard.changeCount
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("OneBar", isDirectory: true)
        root = rootDirectory ?? support.appendingPathComponent("clipboard", isDirectory: true)
        imagesDir = root.appendingPathComponent("images", isDirectory: true)
        thumbsDir = imagesDir.appendingPathComponent("thumbs", isDirectory: true)
        indexURL = root.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: thumbsDir, withIntermediateDirectories: true)

        let storedCode = UserDefaults.standard.object(forKey: "onebar.clip.keyCode") as? Int
        let storedMods = UserDefaults.standard.object(forKey: "onebar.clip.modifiers") as? Int
        if let storedCode, let storedMods {
            hotKey = HotKeySpec(keyCode: UInt32(storedCode), modifiers: UInt32(storedMods))
        } else {
            hotKey = .defaultClip
        }

        let storedRetention = UserDefaults.standard.string(forKey: "onebar.clip.retention")
        retention = storedRetention.flatMap { RetentionPolicy(rawValue: $0) } ?? .threeMonths

        load()
        applyRetention()
        // 先于任何采集入队，串行队列保证不会误删正在写入的新文件
        removeOrphanFiles()
        startTimers()
        // 启动高峰过后再补哈希 / 尺寸 / OCR
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            MainActor.assumeIsolated { self?.backfillImageMeta() }
        }
    }

    // MARK: - 启停

    /// 关闭时停轮询、停清理定时器、注销全局快捷键并暂停 OCR；打开时恢复。
    /// 关闭期间的复制不补录：恢复时以当前 changeCount 为起点。
    func setActive(_ on: Bool) {
        guard on != isActive else { return }
        isActive = on
        if on {
            changeCount = pasteboard.changeCount
            ignoreUntilCount = nil
            startTimers()
            HotKeyCenter.shared.register(hotKey)
            applyRetention()
            pumpOCR()
        } else {
            timer?.invalidate()
            timer = nil
            cleanupTimer?.invalidate()
            cleanupTimer = nil
            recordingHotKey = false
            HotKeyCenter.shared.unregister()
        }
    }

    private func startTimers() {
        timer?.invalidate()
        cleanupTimer?.invalidate()
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.applyRetention() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
    }

    // MARK: - 设置

    func setRetention(_ policy: RetentionPolicy) {
        guard policy != retention else { return }
        retention = policy
        UserDefaults.standard.set(policy.rawValue, forKey: "onebar.clip.retention")
        applyRetention()
    }

    func applyRetention() {
        guard let cutoff = retention.cutoff else { return }
        let expired = items.filter { !$0.isFavorite && $0.createdAt < cutoff }
        guard !expired.isEmpty else { return }
        let expiredIDs = Set(expired.map(\.id))
        items.removeAll { expiredIDs.contains($0.id) }
        expired.forEach(deleteOwnedFiles)
        persist()
    }

    func persistHotKey() {
        UserDefaults.standard.set(Int(hotKey.keyCode), forKey: "onebar.clip.keyCode")
        UserDefaults.standard.set(Int(hotKey.modifiers), forKey: "onebar.clip.modifiers")
        if isActive { HotKeyCenter.shared.register(hotKey) }
    }

    func beginRecordHotKey() {
        recordingHotKey = true
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.recordingHotKey else { return event }
                if event.keyCode == UInt16(kVK_Escape) {
                    self.recordingHotKey = false
                    return nil
                }
                if let spec = HotKeySpec.from(event: event) {
                    self.hotKey = spec
                    self.persistHotKey()
                    self.recordingHotKey = false
                    return nil
                }
                return event
            }
        }
    }

    // MARK: - 取用与编辑

    func restore(_ item: ClipboardItem) {
        pasteboard.clearContents()
        tiffProvider = nil
        switch item.kind {
        case .text:
            pasteboard.setString(item.text ?? item.preview, forType: .string)
        case .image:
            if let path = item.imagePath,
               let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                // PNG 立即写入；TIFF 按需提供，兼顾只认 TIFF 的聊天 / Office 应用
                let pbItem = NSPasteboardItem()
                pbItem.setData(data, forType: .png)
                let provider = TIFFProvider(path: path)
                pbItem.setDataProvider(provider, forTypes: [.tiff])
                tiffProvider = provider
                pasteboard.writeObjects([pbItem])
            }
        case .file:
            let urls = item.filePaths.map { URL(fileURLWithPath: $0) as NSURL }
            pasteboard.writeObjects(urls)
        }
        ignoreUntilCount = pasteboard.changeCount
    }

    /// 复制图片 OCR 出的文字；与 restore 一样不回灌历史。
    func copyRecognizedText(_ item: ClipboardItem) {
        guard let text = items.first(where: { $0.id == item.id })?.recognizedText ?? item.recognizedText else { return }
        pasteboard.clearContents()
        tiffProvider = nil
        pasteboard.setString(text, forType: .string)
        ignoreUntilCount = pasteboard.changeCount
    }

    func toggleFavorite(_ item: ClipboardItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i].isFavorite.toggle()
        persist()
    }

    func clear() {
        items.removeAll()
        persist()
        if let files = try? FileManager.default.contentsOfDirectory(at: imagesDir, includingPropertiesForKeys: nil) {
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
        // thumbs 目录随上面一起删掉了，立即重建
        try? FileManager.default.createDirectory(at: thumbsDir, withIntermediateDirectories: true)
    }

    func remove(_ item: ClipboardItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        let removed = items.remove(at: i)
        deleteOwnedFiles(removed)
        persist()
    }

    /// 只删本目录下我们自己落盘的原图与缩略图；Finder 复制的用户文件绝不碰。
    private func deleteOwnedFiles(_ item: ClipboardItem) {
        for path in [item.imagePath, item.thumbPath].compactMap({ $0 }) where isOwned(path) {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    private func isOwned(_ path: String) -> Bool {
        path.hasPrefix(imagesDir.path + "/")
    }

    private func showNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    // MARK: - 采集

    private func poll() {
        guard isActive else { return }
        let current = pasteboard.changeCount
        guard current != changeCount else { return }
        changeCount = current
        if let skip = ignoreUntilCount, current <= skip {
            return
        }
        ignoreUntilCount = nil
        scheduleCapture()
    }

    private enum Capture: Sendable {
        case item(ClipboardItem)
        case tooLarge(Int)
    }

    /// 粘贴板转换 / 图片落盘 / 缩略图生成都是主线程杀手（复制大图能卡上百毫秒），
    /// 统一挪到串行队列，按顺序回到主线程插入，保证时间序不乱。
    private func scheduleCapture() {
        nonisolated(unsafe) let pb = pasteboard
        let ignored = ignoredTypes
        let images = imagesDir
        let thumbs = thumbsDir
        captureQueue.async { [weak self] in
            guard let result = Self.readItem(from: pb, ignored: ignored, imagesDir: images, thumbsDir: thumbs) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch result {
                    case .item(let item):
                        self.commit(item)
                    case .tooLarge(let bytes):
                        let mb = bytes / 1024 / 1024
                        NSLog("OneBar 剪贴板：图片 %d MB 超过上限 %d MB，未保存", mb, ClipboardMedia.maxImageBytes / 1024 / 1024)
                        self.showNotice("图片 \(mb) MB 超过 \(ClipboardMedia.maxImageBytes / 1024 / 1024) MB 上限，未保存")
                    }
                }
            }
        }
    }

    /// 同内容命中历史：旧条目挪到顶部并刷新时间，保留收藏与 OCR，丢弃新落盘的重复文件。
    /// 历史里早先累积的同内容副本一并合并，任一收藏即视为收藏。
    private func commit(_ item: ClipboardItem) {
        if let hash = item.contentHash,
           let i = items.firstIndex(where: { $0.kind == item.kind && $0.contentHash == hash }) {
            var existing = items.remove(at: i)
            let copies = items.filter { $0.kind == item.kind && $0.contentHash == hash }
            if !copies.isEmpty {
                items.removeAll { $0.kind == item.kind && $0.contentHash == hash }
                let keep = Set([existing.imagePath, existing.thumbPath].compactMap { $0 })
                for copy in copies {
                    existing.isFavorite = existing.isFavorite || copy.isFavorite
                    if existing.ocrText == nil { existing.ocrText = copy.ocrText }
                    for path in [copy.imagePath, copy.thumbPath].compactMap({ $0 }) where isOwned(path) && !keep.contains(path) {
                        try? FileManager.default.removeItem(atPath: path)
                    }
                }
            }
            existing.createdAt = item.createdAt
            if existing.kind == .file {
                // 同路径的文件内容可能已变，元信息以本次为准
                if existing.thumbPath != item.thumbPath, let old = existing.thumbPath, isOwned(old) {
                    try? FileManager.default.removeItem(atPath: old)
                }
                existing.thumbPath = item.thumbPath
                existing.byteCount = item.byteCount
                existing.pixelWidth = item.pixelWidth
                existing.pixelHeight = item.pixelHeight
            } else if existing.kind == .image,
               existing.imagePath.map({ FileManager.default.fileExists(atPath: $0) }) != true {
                // 旧原图已丢失，换用新文件
                deleteOwnedFiles(existing)
                existing.imagePath = item.imagePath
                existing.thumbPath = item.thumbPath
                existing.byteCount = item.byteCount
            } else {
                if existing.thumbPath == nil {
                    existing.thumbPath = item.thumbPath
                }
                for path in [item.imagePath, item.thumbPath].compactMap({ $0 }) where isOwned(path) && path != existing.imagePath && path != existing.thumbPath {
                    try? FileManager.default.removeItem(atPath: path)
                }
            }
            if existing.pixelWidth == nil {
                existing.pixelWidth = item.pixelWidth
                existing.pixelHeight = item.pixelHeight
            }
            items.insert(existing, at: 0)
            persist()
            return
        }
        items.insert(item, at: 0)
        persist()
        if item.isImageLike { pumpOCR() }
    }

    private nonisolated static func readItem(from pasteboard: NSPasteboard, ignored: Set<String>, imagesDir: URL, thumbsDir: URL) -> Capture? {
        let types = Set((pasteboard.types ?? []).map(\.rawValue))
        if !ignored.isDisjoint(with: types) { return nil }

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty, urls.allSatisfy(\.isFileURL) {
            let paths = urls.map(\.path)
            let bytes = paths.reduce(Int64(0)) { sum, path in
                let n = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
                return sum + n
            }
            var item = ClipboardItem(
                id: UUID(),
                kind: .file,
                createdAt: Date(),
                preview: urls.map(\.lastPathComponent).joined(separator: ", "),
                text: nil,
                imagePath: nil,
                filePaths: paths,
                byteCount: bytes,
                isFavorite: false,
                thumbPath: makeThumb(from: paths.first, thumbsDir: thumbsDir),
                charCount: 0,
                contentHash: ClipboardMedia.pathsHash(paths)
            )
            if let path = item.imageSourcePath {
                let info = ClipboardMedia.info(ofFile: path)
                item.pixelWidth = info?.width ?? 0
                item.pixelHeight = info?.height ?? 0
            }
            return .item(item)
        }

        if let data = pasteboard.data(forType: .png) ?? tiffAsPNG(from: pasteboard) {
            if data.count > ClipboardMedia.maxImageBytes { return .tooLarge(data.count) }
            let id = UUID()
            let file = imagesDir.appendingPathComponent("\(id.uuidString).png")
            do { try data.write(to: file, options: .atomic) } catch { return nil }
            let info = ClipboardMedia.info(ofData: data)
            return .item(ClipboardItem(
                id: id,
                kind: .image,
                createdAt: Date(),
                preview: "图片",
                text: nil,
                imagePath: file.path,
                filePaths: [],
                byteCount: Int64(data.count),
                isFavorite: false,
                thumbPath: makeThumb(from: file.path, thumbsDir: thumbsDir),
                charCount: 0,
                contentHash: ClipboardMedia.sha256(data),
                pixelWidth: info?.width ?? 0,
                pixelHeight: info?.height ?? 0
            ))
        }

        if let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            let preview = text.count > 80 ? String(text.prefix(80)) + "…" : text
            return .item(ClipboardItem(
                id: UUID(),
                kind: .text,
                createdAt: Date(),
                preview: preview.replacingOccurrences(of: "\n", with: " "),
                text: text,
                imagePath: nil,
                filePaths: [],
                byteCount: Int64(text.utf8.count),
                isFavorite: false,
                thumbPath: nil,
                charCount: text.count,
                contentHash: ClipboardMedia.textHash(text)
            ))
        }
        return nil
    }

    private nonisolated static func tiffAsPNG(from pasteboard: NSPasteboard) -> Data? {
        guard let tiff = pasteboard.data(forType: .tiff) else { return nil }
        return ClipboardMedia.pngData(fromImageData: tiff)
    }

    private nonisolated static func makeThumb(from source: String?, thumbsDir: URL) -> String? {
        guard let source, ClipboardItem.isImageFile(source),
              FileManager.default.fileExists(atPath: source) else { return nil }
        return ThumbnailMaker.write(from: source, toDirectory: thumbsDir, name: UUID().uuidString)?.path
    }

    // MARK: - 后台补全：哈希 / 尺寸 / 透明缩略图 / OCR / 孤儿文件

    private struct MetaJob: Sendable {
        var id: UUID
        var path: String
        var needHash: Bool
        var needInfo: Bool
        var thumbPath: String?
    }

    private struct MetaResult: Sendable {
        var id: UUID
        var hash: String?
        var info: ClipboardMedia.ImageInfo?
        var newThumb: String?
    }

    /// 旧数据缺哈希 / 尺寸时补算；顺带把透明图的旧 JPEG 黑底缩略图重做成 PNG。
    private func backfillImageMeta() {
        let jobs: [MetaJob] = items.compactMap { item in
            guard let path = item.imageSourcePath else { return nil }
            let needHash = item.kind == .image && item.contentHash == nil
            let needInfo = item.pixelWidth == nil
            guard needHash || needInfo else { return nil }
            return MetaJob(id: item.id, path: path, needHash: needHash, needInfo: needInfo, thumbPath: item.thumbPath)
        }
        guard !jobs.isEmpty else {
            pumpOCR()
            return
        }
        let thumbs = thumbsDir
        let imagesPrefix = imagesDir.path + "/"
        metaQueue.async { [weak self] in
            let results: [MetaResult] = jobs.map { job in
                var result = MetaResult(id: job.id)
                if job.needHash { result.hash = ClipboardMedia.fileHash(job.path) }
                if job.needInfo {
                    let info = ClipboardMedia.info(ofFile: job.path)
                    result.info = info
                    if info?.hasAlpha == true, let old = job.thumbPath, old.hasPrefix(imagesPrefix), old.hasSuffix(".jpg"),
                       let url = ThumbnailMaker.write(from: job.path, toDirectory: thumbs, name: UUID().uuidString) {
                        if url.pathExtension == "png" {
                            result.newThumb = url.path
                        } else {
                            try? FileManager.default.removeItem(at: url)
                        }
                    }
                }
                return result
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.applyMeta(results) }
            }
        }
    }

    private func applyMeta(_ results: [MetaResult]) {
        var index: [UUID: Int] = [:]
        for (i, item) in items.enumerated() { index[item.id] = i }
        var updated = items
        for result in results {
            guard let i = index[result.id] else {
                if let thumb = result.newThumb { try? FileManager.default.removeItem(atPath: thumb) }
                continue
            }
            if let hash = result.hash { updated[i].contentHash = hash }
            if updated[i].pixelWidth == nil {
                updated[i].pixelWidth = result.info?.width ?? 0
                updated[i].pixelHeight = result.info?.height ?? 0
            }
            if let thumb = result.newThumb {
                if let old = updated[i].thumbPath, isOwned(old) { try? FileManager.default.removeItem(atPath: old) }
                updated[i].thumbPath = thumb
            }
        }
        items = updated
        persist()
        pumpOCR()
    }

    /// 每次取 4 张未识别的图片在后台低优先级识别，结果回主线程合并后再取下一批；关闭模块即暂停。
    private func pumpOCR() {
        guard isActive, !ocrRunning else { return }
        let jobs: [(UUID, String)] = Array(items.lazy
            .filter { $0.ocrText == nil }
            .compactMap { item in item.imageSourcePath.map { (item.id, $0) } }
            .prefix(4))
        guard !jobs.isEmpty else { return }
        ocrRunning = true
        ocrQueue.async { [weak self] in
            let results = jobs.map { job in (job.0, ClipboardMedia.recognizeText(at: job.1) ?? "") }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.ocrRunning = false
                    self.applyOCR(results)
                    self.pumpOCR()
                }
            }
        }
    }

    private func applyOCR(_ results: [(UUID, String)]) {
        var updated = items
        var changed = false
        for (id, text) in results {
            guard let i = updated.firstIndex(where: { $0.id == id }) else { continue }
            updated[i].ocrText = text
            changed = true
        }
        guard changed else { return }
        items = updated
        persist()
    }

    /// 清掉 images/ 与 thumbs/ 下不被任何条目引用的文件（历史上 remove 不删缩略图留下的泄漏）。
    /// index.json 存在却解析失败时 items 为空，此时清理会误删全部图片，必须跳过。
    private func removeOrphanFiles() {
        guard indexLoaded else { return }
        let referenced = Set(items.flatMap { [$0.imagePath, $0.thumbPath].compactMap { $0 } })
        let dirs = [imagesDir, thumbsDir]
        captureQueue.async {
            Self.deleteOrphans(in: dirs, referenced: referenced)
        }
    }

    /// 只删一分钟前就存在的普通文件，留出余量避免与正在落盘的新条目抢跑。
    @discardableResult
    nonisolated static func deleteOrphans(in dirs: [URL], referenced: Set<String>, minAge: TimeInterval = 60) -> Int {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        let now = Date()
        var removed = 0
        // 目录枚举返回的是解析过软链的路径（如 /tmp → /private/tmp），两边统一解析后再比
        let referenced = Set(referenced.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { continue }
            for file in files {
                guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                if let modified = values.contentModificationDate, now.timeIntervalSince(modified) < minAge { continue }
                if referenced.contains(file.resolvingSymlinksInPath().path) { continue }
                if (try? fm.removeItem(at: file)) != nil { removed += 1 }
            }
        }
        return removed
    }

    // MARK: - 持久化

    private struct DiskItem: Codable {
        var id: UUID
        var kind: ClipboardItem.Kind
        var createdAt: Date
        var preview: String
        var text: String?
        var imagePath: String?
        var filePaths: [String]
        var byteCount: Int64?
        var isFavorite: Bool?
        var thumbPath: String?
        var charCount: Int?
        var contentHash: String?
        var pixelWidth: Int?
        var pixelHeight: Int?
        var ocrText: String?
    }

    /// 主线程只做结构体拷贝（字符串写时复制，不深拷贝），JSON 编码与写盘在串行队列。
    private func persist() {
        let payload = items.map {
            DiskItem(id: $0.id, kind: $0.kind, createdAt: $0.createdAt, preview: $0.preview,
                     text: $0.text, imagePath: $0.imagePath, filePaths: $0.filePaths,
                     byteCount: $0.byteCount, isFavorite: $0.isFavorite, thumbPath: $0.thumbPath,
                     charCount: $0.charCount, contentHash: $0.contentHash,
                     pixelWidth: $0.pixelWidth, pixelHeight: $0.pixelHeight, ocrText: $0.ocrText)
        }
        let url = indexURL
        persistQueue.async {
            guard let data = try? JSONEncoder().encode(payload) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// 等待已排队的写盘完成（自测用）。
    func flushPersist() {
        persistQueue.sync {}
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            indexLoaded = true
            return
        }
        guard let data = try? Data(contentsOf: indexURL),
              let payload = try? JSONDecoder().decode([DiskItem].self, from: data) else { return }
        indexLoaded = true
        items = payload.map {
            var bytes = $0.byteCount ?? 0
            if bytes == 0 {
                if let path = $0.imagePath {
                    bytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
                } else {
                    bytes = $0.filePaths.reduce(Int64(0)) { sum, path in
                        sum + ((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0)
                    }
                }
            }
            var thumb = $0.thumbPath
            if let t = thumb, !FileManager.default.fileExists(atPath: t) {
                thumb = nil
            }
            let chars = $0.charCount ?? $0.text?.count ?? $0.preview.count
            // 文本 / 文件的哈希是纯内存计算（整份历史 < 1 ms），就地补上；图片要读文件，留给后台
            var hash = $0.contentHash
            if hash == nil {
                switch $0.kind {
                case .text: hash = $0.text.map(ClipboardMedia.textHash)
                case .file: hash = ClipboardMedia.pathsHash($0.filePaths)
                case .image: break
                }
            }
            return ClipboardItem(id: $0.id, kind: $0.kind, createdAt: $0.createdAt, preview: $0.preview,
                                 text: $0.text, imagePath: $0.imagePath, filePaths: $0.filePaths,
                                 byteCount: bytes, isFavorite: $0.isFavorite ?? false, thumbPath: thumb,
                                 charCount: chars, contentHash: hash,
                                 pixelWidth: $0.pixelWidth, pixelHeight: $0.pixelHeight, ocrText: $0.ocrText)
        }
    }
}
