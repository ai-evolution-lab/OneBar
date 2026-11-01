import AppKit
import Foundation
import ImageIO
import SwiftUI

enum ThumbnailMaker {
    /// 生成缩略图写入目录：有真实透明像素存 PNG（JPEG 会把透明变黑底），否则存 JPEG。返回写入的文件。
    static func write(from sourcePath: String, toDirectory dir: URL, name: String, maxPixel: CGFloat = 360) -> URL? {
        let srcURL = URL(fileURLWithPath: sourcePath) as CFURL
        guard let source = CGImageSourceCreateWithURL(srcURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: false
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let transparent = ClipboardMedia.hasTransparency(cgImage)
        let dest = dir.appendingPathComponent(name).appendingPathExtension(transparent ? "png" : "jpg")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = NSMutableData()
        let type = (transparent ? "public.png" : "public.jpeg") as CFString
        guard let out = CGImageDestinationCreateWithData(data, type, 1, nil) else { return nil }
        let props: [CFString: Any] = transparent ? [:] : [kCGImageDestinationLossyCompressionQuality: 0.72]
        CGImageDestinationAddImage(out, cgImage, props as CFDictionary)
        guard CGImageDestinationFinalize(out) else { return nil }
        do {
            try (data as Data).write(to: dest, options: .atomic)
            return dest
        } catch {
            return nil
        }
    }
}

final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()
    private let queue = DispatchQueue(label: "onebar.thumb", qos: .userInitiated)

    init() {
        cache.countLimit = 300
        cache.totalCostLimit = 48 * 1024 * 1024
    }

    /// 同步查缓存（NSCache 线程安全），命中时视图首帧即出图，滚动回来不闪白。
    func cached(_ path: String, maxPixel: Int = 220) -> NSImage? {
        cache.object(forKey: key(path, maxPixel))
    }

    private func key(_ path: String, _ maxPixel: Int) -> NSString {
        "\(maxPixel)|\(path)" as NSString
    }

    func image(for path: String, maxPixel: Int = 220) async -> NSImage? {
        let keyString = "\(maxPixel)|\(path)"
        if let hit = cache.object(forKey: keyString as NSString) { return hit }
        return await withCheckedContinuation { cont in
            queue.async { [path] in
                let url = URL(fileURLWithPath: path)
                let srcURL = url as CFURL
                let image: NSImage?
                // 行高约 80pt，220px 足够 2x 屏清晰；在本队列立即解码，
                // 推迟到首次绘制会在滚动中卡主线程。
                if let source = CGImageSourceCreateWithURL(srcURL, [kCGImageSourceShouldCache: false] as CFDictionary) {
                    let options: [CFString: Any] = [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                        kCGImageSourceShouldCacheImmediately: true
                    ]
                    if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                        image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                    } else {
                        image = nil
                    }
                } else {
                    image = nil
                }
                if let image {
                    let cost = Int(image.size.width * image.size.height * 4)
                    self.cache.setObject(image, forKey: keyString as NSString, cost: cost)
                }
                cont.resume(returning: image)
            }
        }
    }
}

struct ThumbnailView: View {
    let path: String
    var maxPixel: Int = 220
    var height: CGFloat? = 80
    @State private var image: NSImage?

    init(path: String, maxPixel: Int = 220, height: CGFloat? = 80) {
        self.path = path
        self.maxPixel = maxPixel
        self.height = height
        _image = State(initialValue: ThumbnailCache.shared.cached(path, maxPixel: maxPixel))
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.06))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(height == nil ? .high : .medium)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: height ?? .infinity, alignment: height == nil ? .center : .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if height == nil {
                ProgressView().controlSize(.small)
            }
        }
        .frame(height: height)
        .task(id: path) {
            // 复用的视图换了 path 时，先清掉旧图（命中缓存则直接换上）
            if let hit = ThumbnailCache.shared.cached(path, maxPixel: maxPixel) {
                image = hit
                return
            }
            image = nil
            image = await ThumbnailCache.shared.image(for: path, maxPixel: maxPixel)
        }
    }
}
