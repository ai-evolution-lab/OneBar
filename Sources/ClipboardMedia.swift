import AppKit
import CommonCrypto
import Foundation
import ImageIO
import Vision

/// 剪贴板图片 / 哈希 / OCR 工具：全是无状态纯函数，可在任意后台队列调用。
enum ClipboardMedia {
    /// 单张图片上限；超过只提示不保存，避免一次复制写爆磁盘。
    static let maxImageBytes = 80 * 1024 * 1024

    static func sha256(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buf in
            _ = CC_SHA256(buf.baseAddress, CC_LONG(buf.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func textHash(_ text: String) -> String {
        sha256(Data(text.utf8))
    }

    /// 文件条目按路径列表判重：内容可能很大，且同一路径就是同一份取用。
    static func pathsHash(_ paths: [String]) -> String {
        sha256(Data(paths.joined(separator: "\n").utf8))
    }

    static func fileHash(_ path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else { return nil }
        return sha256(data)
    }

    /// 任意 ImageIO 能读的格式（TIFF 等）直接转 PNG，不经 NSImage / BitmapRep 两轮解码。
    static func pngData(fromImageData data: Data) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return encode(src, type: "public.png")
    }

    /// 给需要 TIFF 的应用（部分聊天 / Office）现转一份。
    static func tiffData(fromFile path: String) -> Data? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let src = CGImageSourceCreateWithURL(url, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return encode(src, type: "public.tiff")
    }

    private static func encode(_ src: CGImageSource, type: String) -> Data? {
        guard CGImageSourceGetCount(src) > 0 else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImageFromSource(dest, src, 0, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    struct ImageInfo: Sendable {
        var width: Int
        var height: Int
        var hasAlpha: Bool
    }

    static func info(ofData data: Data) -> ImageInfo? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return info(of: src)
    }

    static func info(ofFile path: String) -> ImageInfo? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let src = CGImageSourceCreateWithURL(url, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return info(of: src)
    }

    /// 只读文件头属性，不解码像素。
    private static func info(of src: CGImageSource) -> ImageInfo? {
        guard CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else { return nil }
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let alpha = (props[kCGImagePropertyHasAlpha] as? NSNumber)?.boolValue ?? false
        // EXIF 5~8 为旋转 90°，显示尺寸宽高互换
        return orientation >= 5 ? ImageInfo(width: h, height: w, hasAlpha: alpha) : ImageInfo(width: w, height: h, hasAlpha: alpha)
    }

    /// 有 alpha 通道不代表真透明（很多截图带满不透明 alpha），逐像素看一眼缩略图才准。
    static func hasTransparency(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: break
        }
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return false }
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        return buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return true }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            var i = 3
            while i < raw.count {
                if raw[i] < 255 { return true }
                i += 4
            }
            return false
        }
    }

    /// 中英文精确识别；失败返回 nil。耗时 0.2~1 秒，只能在后台队列调用。
    static func recognizeText(at path: String) -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(url: URL(fileURLWithPath: path), options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }
}
