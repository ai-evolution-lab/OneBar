import AppKit
import Foundation
import ImageIO
import SwiftUI

enum ThumbnailMaker {
    static func write(from sourcePath: String, to dest: URL, maxPixel: CGFloat = 360) -> Bool {
        let srcURL = URL(fileURLWithPath: sourcePath) as CFURL
        guard let source = CGImageSourceCreateWithURL(srcURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return false
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: false
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return false
        }
        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.72]) else { return false }
        do {
            try data.write(to: dest, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()
    private let queue = DispatchQueue(label: "onebar.thumb", qos: .userInitiated)

    init() {
        cache.countLimit = 80
        cache.totalCostLimit = 16 * 1024 * 1024
    }

    func image(for path: String) async -> NSImage? {
        let key = path as NSString
        if let hit = cache.object(forKey: key) { return hit }
        return await withCheckedContinuation { cont in
            queue.async { [path] in
                let url = URL(fileURLWithPath: path)
                let srcURL = url as CFURL
                let image: NSImage?
                if let source = CGImageSourceCreateWithURL(srcURL, [kCGImageSourceShouldCache: false] as CFDictionary) {
                    let options: [CFString: Any] = [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 360,
                        kCGImageSourceShouldCacheImmediately: false
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
                    self.cache.setObject(image, forKey: path as NSString, cost: Int(image.size.width * image.size.height))
                }
                cont.resume(returning: image)
            }
        }
    }
}

struct ThumbnailView: View {
    let path: String
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.06))
                .frame(height: 80)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 80, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(height: 80)
        .task(id: path) {
            image = await ThumbnailCache.shared.image(for: path)
        }
    }
}
