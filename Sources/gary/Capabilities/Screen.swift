import AppKit
import GaryCore
import ScreenCaptureKit

extension Capability {
    static let screen = Capability(
        name: "screen",
        summary: """
        Capture a display, a window, or a region of the screen to a PNG file and the clipboard. `select()` lets the user drag a region or \
        click a window or the desktop, and resolves with that area, or null after escape or a right click. A region is in points from the \
        top left of the main display. Hide the plugin's own surface before you select or capture, or it shows in the image.
        """,
        types: """
        declare namespace Gary {
          interface Host { screen: ScreenApi }
          interface ScreenApi {
            select(): Promise<ScreenArea | null>;
            capture(area: ScreenArea, options?: { path?: string; clipboard?: boolean }): Promise<string>;
          }
        }
        """,
        example: """
        export default {
          async onAction() {
            host.hide();
            const area = await host.screen.select();
            if (!area) return;
            const path = await host.screen.capture(area, { path: `~/Pictures/Screenshot ${Date.now()}.png`, clipboard: true });
            host.log(`saved ${path}`);
          },
          render() {
            return { type: "text", text: "Screenshot", action: "shoot" };
          },
        } satisfies Gary.Menu;
        """,
        permissions: [.screenRecording],
        install: { host, plugin in
            let folder = plugin.bundle.directory.path
            plugin.installAPI(host, "screen", ScreenRequest.methods) { call in
                switch try ScreenRequest.parse(call, home: home, folder: folder) {
                case .select:
                    .pending { finish in DispatchQueue.main.async { ScreenSelection.run(finish) } }
                case let .capture(area, path, clipboard):
                    .task { try await .string(screenshot(area, to: path, clipboard: clipboard)) }
                }
            }
        },
    )
}

extension HostResult {
    static func task(_ work: @escaping () async throws -> JSON) -> HostResult {
        .pending { finish in
            Task {
                do {
                    try await finish(.success(work()))
                } catch {
                    finish(.failure(error))
                }
            }
        }
    }
}

private func screenshot(_ area: ScreenArea, to path: String?, clipboard: Bool) async throws -> String {
    let image = try await captureImage(area)
    guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        throw HostFailure("the capture cannot be encoded as PNG")
    }
    if clipboard {
        let board = NSPasteboard.general
        board.clearContents()
        board.setData(png, forType: .png)
    }
    guard let path else { return try savePNG(png, in: "screen") }
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try png.write(to: url, options: .atomic)
    return path
}

func captureImage(_ area: ScreenArea) async throws -> CGImage {
    guard CGPreflightScreenCaptureAccess() else { throw HostFailure(missingGrant(.screenRecording, "screen capture")) }
    if case let .region(rect) = area {
        return try await SCScreenshotManager.captureImage(in: rect)
    }
    let source = try await captureSource(area)
    return try await SCScreenshotManager.captureImage(contentFilter: source.filter, configuration: source.configuration)
}

func captureSource(_ area: ScreenArea) async throws -> (filter: SCContentFilter, configuration: SCStreamConfiguration) {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    let filter: SCContentFilter
    var rect: CGRect?
    switch area {
    case let .display(id):
        guard let display = content.displays.first(where: { displayID(id) == $0.displayID }) else { throw HostFailure("no display \(id ?? "main")") }
        filter = SCContentFilter(display: display, excludingWindows: [])
    case let .window(id):
        guard let window = content.windows.first(where: { $0.windowID == id }) else { throw HostFailure("no window \(id) on screen") }
        filter = SCContentFilter(desktopIndependentWindow: window)
    case let .region(region):
        guard let display = content.displays.first(where: { $0.frame.contains(region) }) else {
            throw HostFailure("the region must lie on one display")
        }
        filter = SCContentFilter(display: display, excludingWindows: [])
        rect = region.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
    }
    let configuration = SCStreamConfiguration()
    let size = rect?.size ?? filter.contentRect.size
    configuration.width = Int((size.width * CGFloat(filter.pointPixelScale)).rounded())
    configuration.height = Int((size.height * CGFloat(filter.pointPixelScale)).rounded())
    configuration.sourceRect = rect ?? .null
    configuration.showsCursor = false
    return (filter, configuration)
}

private func displayID(_ uuid: String?) -> CGDirectDisplayID? {
    guard let uuid else { return CGMainDisplayID() }
    let screen = NSScreen.screens.first { $0.uuid == uuid }
    return (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
}
