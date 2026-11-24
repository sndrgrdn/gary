import AppKit
import GaryCore
import SwiftUI

private nonisolated(unsafe) let images: NSCache<NSString, Bitmap> = {
    let cache = NSCache<NSString, Bitmap>()
    cache.totalCostLimit = 256 << 20
    return cache
}()

private let decoder = DispatchQueue(label: "gary.images", qos: .userInitiated)
private let decodeAtOnceLimit = 32 << 10
private let keptAfterHiding = 60.0

struct ImageNode: View {
    let path: String
    let fit: ImageFit
    let size: CGSize
    let tint: Color?
    let arrival: SwiftUI.Animation?
    let transition: AnyTransition
    @Environment(\.displayScale) private var scale
    @Environment(\.opening) private var opening
    private let kept = State<(image: NSImage, opening: Int)?>(initialValue: nil)

    var body: some View {
        let pixels = CGSize(width: (size.width * scale).rounded(.up), height: (size.height * scale).rounded(.up))
        let key = "\(path)|\(Int(pixels.width))x\(Int(pixels.height))|\(fit.rawValue)" as NSString
        let shown = kept.wrappedValue.flatMap { $0.opening == opening ? $0.image : nil }
        ZStack {
            if let image = cached(key) ?? (isSmall(path) ? decoded(path, pixels, fit, key)?.image() : nil) ?? shown {
                Image(nsImage: image).renderingMode(tint == nil ? .original : .template).resizable().interpolation(.high)
                    .aspectRatio(contentMode: fit == .fill ? .fill : .fit).foregroundStyle(tint ?? .primary).transition(transition)
            }
        }
        .task(id: key) {
            guard cached(key) == nil, let image = await decode(path, pixels, fit, key as String)?.image() else { return }
            withAnimation(shown == nil ? arrival : nil) { kept.wrappedValue = (image, opening) }
        }
        .onDisappear {
            let image = cached(key) ?? kept.wrappedValue?.image
            DispatchQueue.main.asyncAfter(deadline: .now() + keptAfterHiding) { _ = image }
        }
    }
}

final nonisolated class Bitmap: @unchecked Sendable {
    private static let space = CGColorSpace(name: CGColorSpace.displayP3)
    private static let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    private let pixels: NSPurgeableData
    let width: Int
    let height: Int
    private let space: CGColorSpace
    private weak var shown: NSImage?

    init?(width: Int, height: Int, draw: (CGContext) -> Void) {
        guard let pixels = NSPurgeableData(length: width * height * 4), let space = Self.space,
              let context = CGContext(
                  data: pixels.mutableBytes,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: space,
                  bitmapInfo: Self.info,
              )
        else { return nil }
        draw(context)
        pixels.endContentAccess()
        self.pixels = pixels
        self.width = width
        self.height = height
        self.space = space
    }

    @MainActor func image() -> NSImage? {
        if let shown {
            return shown
        }
        guard pixels.beginContentAccess() else { return nil }
        let provider = CGDataProvider(dataInfo: Unmanaged.passRetained(pixels).toOpaque(), data: pixels.bytes, size: pixels.length) { info, _, _ in
            guard let info else { return }
            Unmanaged<NSPurgeableData>.fromOpaque(info).takeRetainedValue().endContentAccess()
        }
        guard let provider, let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: Self.info),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent,
        )
        else { return nil }
        let shown = NSImage(cgImage: image, size: NSSize(width: width, height: height))
        self.shown = shown
        return shown
    }
}

private func cached(_ key: NSString) -> NSImage? {
    guard let bitmap = images.object(forKey: key) else { return nil }
    guard let image = bitmap.image() else {
        images.removeObject(forKey: key)
        return nil
    }
    return image
}

private final nonisolated class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}

private func decode(_ path: String, _ pixels: CGSize, _ fit: ImageFit, _ key: String) async -> Bitmap? {
    let cancellation = Cancellation()
    return await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
            decoder.async {
                continuation.resume(returning: cancellation.isCancelled ? nil : decoded(path, pixels, fit, key as NSString))
            }
        }
    } onCancel: {
        cancellation.cancel()
    }
}

private func isSmall(_ path: String) -> Bool {
    let attributes = try? FileManager.default.attributesOfItem(atPath: path)
    return attributes?[.type] as? FileAttributeType == .typeRegular && (attributes?[.size] as? Int ?? .max) <= decodeAtOnceLimit
}

private nonisolated func decoded(_ path: String, _ pixels: CGSize, _ fit: ImageFit, _ key: NSString) -> Bitmap? {
    guard let bitmap = load(path, pixels, fit) else { return nil }
    images.setObject(bitmap, forKey: key, cost: bitmap.width * bitmap.height * 4)
    return bitmap
}

private nonisolated func load(_ path: String, _ pixels: CGSize, _ fit: ImageFit) -> Bitmap? {
    if path.hasSuffix(".app") {
        return drawn(NSWorkspace.shared.icon(forFile: path), pixels, fit)
    }
    let url = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?,
          let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
          let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
              kCGImageSourceCreateThumbnailFromImageAlways: true,
              kCGImageSourceCreateThumbnailWithTransform: true,
              kCGImageSourceShouldCacheImmediately: true,
              kCGImageSourceThumbnailMaxPixelSize: fit.pixelSize(source: CGSize(width: width, height: height), frame: pixels),
          ] as CFDictionary)
    else { return NSImage(contentsOf: url).flatMap { drawn($0, pixels, fit) } }
    return Bitmap(width: image.width, height: image.height) { $0.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height)) }
}

private nonisolated func drawn(_ image: NSImage, _ pixels: CGSize, _ fit: ImageFit) -> Bitmap? {
    guard image.size.width > 0, image.size.height > 0 else { return nil }
    let widthRatio = pixels.width / image.size.width
    let heightRatio = pixels.height / image.size.height
    let ratio = fit == .fill ? max(widthRatio, heightRatio) : min(widthRatio, heightRatio)
    let size = CGSize(width: (image.size.width * ratio).rounded(.up), height: (image.size.height * ratio).rounded(.up))
    return Bitmap(width: Int(size.width), height: Int(size.height)) { context in
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.current = nil
    }
}
