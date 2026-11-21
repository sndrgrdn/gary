import AppKit
import GaryCore
import SwiftUI

private let images: NSCache<NSString, NSImage> = {
    let cache = NSCache<NSString, NSImage>()
    cache.totalCostLimit = 256 << 20
    return cache
}()

private let decoder = DispatchQueue(label: "gary.images", qos: .userInitiated)
private let decodeAtOnceLimit = 32 << 10

struct ImageNode: View {
    let path: String
    let fit: ImageFit
    let size: CGSize
    let arrival: SwiftUI.Animation?
    let transition: AnyTransition
    @Environment(\.displayScale) private var scale
    private let shown = State<NSImage?>(initialValue: nil)

    var body: some View {
        let pixels = CGSize(width: (size.width * scale).rounded(.up), height: (size.height * scale).rounded(.up))
        let key = "\(path)|\(Int(pixels.width))x\(Int(pixels.height))|\(fit.rawValue)" as NSString
        ZStack {
            if let image = images.object(forKey: key) ?? (isSmall(path) ? decoded(path, pixels, fit, key) : nil) ?? shown.wrappedValue {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: fit == .fill ? .fill : .fit).transition(transition)
            }
        }
        .task(id: key) {
            guard images.object(forKey: key) == nil, let image = await decode(path, pixels, fit, key as String) else { return }
            withAnimation(shown.wrappedValue == nil ? arrival : nil) { shown.wrappedValue = image }
        }
    }
}

private final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}

private func decode(_ path: String, _ pixels: CGSize, _ fit: ImageFit, _ key: String) async -> NSImage? {
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
    let attributes = try? FileManager.default.attributesOfItem(atPath: (path as NSString).expandingTildeInPath)
    return attributes?[.type] as? FileAttributeType == .typeRegular && (attributes?[.size] as? Int ?? .max) <= decodeAtOnceLimit
}

private func decoded(_ path: String, _ pixels: CGSize, _ fit: ImageFit, _ key: NSString) -> NSImage? {
    guard let image = load(path, pixels, fit) else { return nil }
    images.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * 4))
    return image
}

private func load(_ path: String, _ pixels: CGSize, _ fit: ImageFit) -> NSImage? {
    let expanded = (path as NSString).expandingTildeInPath
    if expanded.hasSuffix(".app") {
        return NSWorkspace.shared.icon(forFile: expanded)
    }
    let url = URL(fileURLWithPath: expanded)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
          let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
              kCGImageSourceCreateThumbnailFromImageAlways: true,
              kCGImageSourceCreateThumbnailWithTransform: true,
              kCGImageSourceShouldCacheImmediately: true,
              kCGImageSourceThumbnailMaxPixelSize: fit.pixelSize(source: CGSize(width: width, height: height), frame: pixels),
          ] as CFDictionary)
    else { return NSImage(contentsOf: url) }
    return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
}
