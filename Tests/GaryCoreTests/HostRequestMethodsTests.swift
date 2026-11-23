@testable import GaryCore
import Testing

private let home = "/Users/gary"
private let folder = "/Users/gary/plugins/clock"

struct HostRequestMethodsTests {
    private struct Request {
        let api: String?
        let methods: [String]
        let arguments: [JSON]
        let parse: (HostCall) throws -> Void

        init(_ api: String?, _ methods: [String], _ arguments: [JSON], _ parse: @escaping (HostCall) throws -> Void) {
            self.api = api
            self.methods = methods
            self.arguments = arguments
            self.parse = parse
        }
    }

    private let requests: [Request] = [
        Request(nil, FilesRequest.methods, ["/tmp/a.txt", "hi"]) { _ = try FilesRequest.parse($0, home: home, folder: folder) },
        Request("apps", AppsRequest.methods, ["com.apple.Calculator"]) { _ = try AppsRequest.parse($0, home: home) },
        Request("calendar", CalendarRequest.methods, [0, 86_400_000]) { _ = try CalendarRequest.parse($0) },
        Request("clipboard", ClipboardRequest.methods, ["/tmp/a.png"]) { _ = try ClipboardRequest.parse($0, home: home, folder: folder) },
        Request("audio", AudioRequest.methods, [0.5]) { _ = try AudioRequest.parse($0) },
        Request("brightness", BrightnessRequest.methods, [0.5]) { _ = try BrightnessRequest.parse($0) },
        Request("nowplaying", NowPlayingRequest.methods, [42]) { _ = try NowPlayingRequest.parse($0) },
        Request("notifications", NotificationsRequest.methods, [812]) { _ = try NotificationsRequest.parse($0) },
        Request("wifi", WiFiRequest.methods, ["Home"]) { _ = try WiFiRequest.parse($0) },
        Request("bluetooth", BluetoothRequest.methods, ["aa-bb-cc-dd-ee-ff"]) { _ = try BluetoothRequest.parse($0) },
        Request("dock", DockRequest.methods, ["bottom", 60]) { _ = try DockRequest.parse($0) },
        Request("menubar", MenuBarRequest.methods, []) { _ = try MenuBarRequest.parse($0) },
        Request("notify", NotifyRequest.methods, [["title": "Hi"]]) { _ = try NotifyRequest.parse($0) },
        Request("permissions", PermissionsRequest.methods, ["screen-recording"]) { _ = try PermissionsRequest.parse($0) },
        Request("screen", ScreenRequest.methods, [[:], "/tmp/a.mov"]) { _ = try ScreenRequest.parse($0, home: home, folder: folder) },
        Request("tray", TrayRequest.methods, ["com.brnbw.dinky#1"]) { _ = try TrayRequest.parse($0) },
        Request("vision", VisionRequest.methods, ["/tmp/a.png"]) { _ = try VisionRequest.parse($0, home: home, folder: folder) },
        Request("wallpaper", WallpaperRequest.methods, ["/tmp/a.png"]) { _ = try WallpaperRequest.parse($0, home: home, folder: folder) },
    ]

    @Test func `every listed method has its own parse case`() {
        for request in requests {
            for method in request.methods {
                let call = HostCall(api: request.api, method: method, arguments: request.arguments)
                var thrown: Error?
                do { try request.parse(call) } catch { thrown = error }
                #expect(thrown as? ArgumentError != call.unknownMethod)
            }
        }
    }
}
