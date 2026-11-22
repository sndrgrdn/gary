import Foundation
@testable import GaryCore
import Testing

private let home = "/Users/gary"
private let folder = "/Users/gary/plugins/clock"

private func call(_ api: String?, _ method: String, _ arguments: JSON...) -> HostCall {
    HostCall(api: api, method: method, arguments: arguments)
}

struct HostCallTests {
    @Test func `paths are absolute home relative or plugin relative and come back normalised`() {
        #expect(absolutePath("~", home: home, folder: folder) == "/Users/gary")
        #expect(absolutePath("~/notes/../clips/a.txt", home: home, folder: folder) == "/Users/gary/clips/a.txt")
        #expect(absolutePath("/tmp//gary/./x", home: home, folder: folder) == "/tmp/gary/x")
        #expect(absolutePath("/tmp/../../x", home: home, folder: folder) == "/x")
        #expect(absolutePath("notes.txt", home: home, folder: folder) == "/Users/gary/plugins/clock/notes.txt")
        #expect(absolutePath("./icons/../notes.txt", home: home, folder: folder) == "/Users/gary/plugins/clock/notes.txt")
        #expect(absolutePath("../theme/a.txt", home: home, folder: folder) == "/Users/gary/plugins/theme/a.txt")
        #expect(absolutePath("~other/notes.txt", home: home, folder: folder) == nil)
        #expect(absolutePath("", home: home, folder: folder) == nil)
    }

    @Test func `errors name the host function the plugin called`() {
        #expect(call("dock", "reserve").fail("size must be a number").description == "host.dock.reserve: size must be a number")
        #expect(call(nil, "writeFile").unknownMethod.description == "host.writeFile is not a method")
    }
}

struct FilesRequestTests {
    @Test func `each method takes A path and write file takes text`() throws {
        #expect(try FilesRequest.parse(call(nil, "readFile", .string("~/a.txt")), home: home, folder: folder) == .read(path: "/Users/gary/a.txt"))
        #expect(try FilesRequest.parse(call(nil, "writeFile", .string("/tmp/a.txt"), .string("hi")), home: home, folder: folder) == .write(
            path: "/tmp/a.txt",
            text: "hi",
        ))
        #expect(try FilesRequest
            .parse(call(nil, "mkdir", .string("~/cache/clips")), home: home, folder: folder) == .makeDirectory(path: "/Users/gary/cache/clips"))
        #expect(try FilesRequest
            .parse(call(nil, "remove", .string("~/cache/clips")), home: home, folder: folder) == .remove(path: "/Users/gary/cache/clips"))
        #expect(try FilesRequest.parse(call(nil, "list", .string("/tmp")), home: home, folder: folder) == .list(path: "/tmp"))
        #expect(try FilesRequest.parse(call(nil, "readFile", .string("app_icons.tsv")), home: home, folder: folder)
            == .read(path: "/Users/gary/plugins/clock/app_icons.tsv"))
    }

    @Test func `rejects missing text and unknown methods`() {
        #expect(throws: ArgumentError("host.writeFile: text must be a string")) {
            try FilesRequest.parse(call(nil, "writeFile", .string("/tmp/a.txt")), home: home, folder: folder)
        }
        #expect(throws: ArgumentError.self) { try FilesRequest.parse(call(nil, "list", .number(3)), home: home, folder: folder) }
        #expect(throws: ArgumentError("host.chmod is not a method")) { try FilesRequest.parse(
            call(nil, "chmod", .string("/tmp")),
            home: home,
            folder: folder,
        ) }
    }

    @Test func `remove refuses the root the home folder and the plugin folder`() {
        for raw in ["/", "~", "~/", "/Users/gary/.", "."] {
            #expect(throws: ArgumentError.self) { try FilesRequest.parse(call(nil, "remove", .string(raw)), home: home, folder: folder) }
        }
    }
}

struct ClipboardRequestTests {
    private func parse(_ method: String, _ arguments: JSON...) throws -> ClipboardRequest {
        try ClipboardRequest.parse(HostCall(api: "clipboard", method: method, arguments: arguments), home: home, folder: folder)
    }

    @Test func `read takes nothing and write text takes A string`() throws {
        #expect(try parse("read") == .read)
        #expect(try parse("writeText", .string("hello")) == .write(.text("hello", concealed: false)))
        #expect(try parse("writeText", .string("otp"), .bool(true)) == .write(.text("otp", concealed: true)))
        #expect(throws: ArgumentError.self) { try parse("writeText", .string("otp"), .string("yes")) }
        #expect(throws: ArgumentError("host.clipboard.writeText: text must be a string")) { try parse("writeText", .number(5)) }
        #expect(throws: ArgumentError.self) { try parse("clear") }
    }

    @Test func `write image and write files take paths resolved like other host paths`() throws {
        #expect(try parse("writeImage", .string("~/shot.png")) == .write(.image(path: "/Users/gary/shot.png")))
        #expect(try parse("writeFiles", .array([.string("/tmp/a.txt"), .string("icons/b.png")])) == .write(.files(paths: [
            "/tmp/a.txt", "/Users/gary/plugins/clock/icons/b.png",
        ])))
        for paths in [JSON.array([]), .array([.string("")]), .array([.number(1)]), .string("/tmp/a.txt")] {
            #expect(throws: ArgumentError.self) { try parse("writeFiles", paths) }
        }
        #expect(throws: ArgumentError.self) { try parse("writeImage") }
    }
}

struct PermissionsRequestTests {
    @Test func `request takes A permission name`() throws {
        #expect(try PermissionsRequest.parse(call("permissions", "request", .string("screen-recording"))) == .request(.screenRecording))
        #expect(throws: ArgumentError.self) { try PermissionsRequest.parse(call("permissions", "request", .string("camera"))) }
        #expect(throws: ArgumentError("host.permissions.grant is not a method")) { try PermissionsRequest.parse(call("permissions", "grant")) }
        #expect(try PermissionsRequest.parse(call("permissions", "restart")) == .restart)
    }
}

struct WallpaperRequestTests {
    @Test func `set takes an image path and an optional display`() throws {
        #expect(try WallpaperRequest.parse(call("wallpaper", "get"), home: home, folder: folder) == .get)
        #expect(try WallpaperRequest.parse(call("wallpaper", "set", .string("~/Pictures/a.png")), home: home, folder: folder)
            == .set(path: "/Users/gary/Pictures/a.png", display: nil))
        #expect(try WallpaperRequest.parse(call("wallpaper", "set", .string("/a.png"), .null), home: home, folder: folder) == .set(
            path: "/a.png",
            display: nil,
        ))
        #expect(try WallpaperRequest.parse(call("wallpaper", "set", .string("/a.png"), .string("37D8")), home: home, folder: folder) == .set(
            path: "/a.png",
            display: "37D8",
        ))
        #expect(try WallpaperRequest.parse(call("wallpaper", "set", .string("walls/a.png")), home: home, folder: folder)
            == .set(path: "/Users/gary/plugins/clock/walls/a.png", display: nil))
        #expect(throws: ArgumentError("host.wallpaper.set: display must be a string")) {
            try WallpaperRequest.parse(call("wallpaper", "set", .string("/a.png"), .number(0)), home: home, folder: folder)
        }
    }
}

struct MenuBarRequestTests {
    @Test func `hide restore and state take no arguments`() throws {
        #expect(try MenuBarRequest.methods.map { try MenuBarRequest.parse(call("menubar", $0)) } == [.hide, .restore, .state])
        #expect(throws: ArgumentError("host.menubar.show is not a method")) { try MenuBarRequest.parse(call("menubar", "show")) }
    }
}

struct DockRequestTests {
    private let screen = CGSize(width: 1728, height: 1117)

    private func reservation(_ edge: String, _ size: Double) throws -> DockReservation {
        guard case let .reserve(reservation) = try DockRequest.parse(call("dock", "reserve", .string(edge), .number(size))) else {
            throw ArgumentError("not a reservation")
        }
        return reservation
    }

    @Test func `reservations become dock rects along their edge in window server coordinates`() throws {
        let bottom = try reservation("bottom", 60)
        #expect(bottom.rect(in: screen) == CGRect(x: 0, y: 1057, width: 1728, height: 60))
        #expect(bottom.orientation == 2)
        let left = try reservation("left", 60)
        #expect(left.rect(in: screen) == CGRect(x: 0, y: 0, width: 60, height: 1117))
        #expect(left.orientation == 3)
        let right = try reservation("right", 60)
        #expect(right.rect(in: screen) == CGRect(x: 1668, y: 0, width: 60, height: 1117))
        #expect(right.orientation == 4)
    }

    @Test func `a reservation takes at most half the screen`() throws {
        #expect(try reservation("bottom", 558.5).rect(in: screen) != nil)
        #expect(try reservation("bottom", 559).rect(in: screen) == nil)
        #expect(try reservation("left", 865).rect(in: screen) == nil)
    }

    @Test func `rejects the top edge and sizes that are not positive numbers`() {
        #expect(throws: ArgumentError("host.dock.reserve: edge must be one of bottom, left, right")) {
            try DockRequest.parse(call("dock", "reserve", .string("top"), .number(30)))
        }
        for size in [JSON.number(0), .number(-4), .string("60"), .null] {
            #expect(throws: ArgumentError.self) { try DockRequest.parse(call("dock", "reserve", .string("bottom"), size)) }
        }
    }

    @Test func `the other methods take no arguments`() throws {
        let parsed = try DockRequest.methods.dropFirst().map { try DockRequest.parse(call("dock", $0)) }
        #expect(parsed == [.release, .hide, .show, .restore, .state])
    }
}

struct ClaimsTests {
    @Test func `the latest claim wins and releasing it falls back to the one before`() {
        var claims = Claims<String, Bool>()
        #expect(claims.current == nil)
        claims.claim(true, by: "dock")
        claims.claim(false, by: "launcher")
        #expect(claims.current == false)
        claims.release("launcher")
        #expect(claims.current == true)
        claims.release("dock")
        #expect(claims.current == nil)
    }

    @Test func `claiming again moves an owner to the front`() {
        var claims = Claims<String, Int>()
        claims.claim(1, by: "a")
        claims.claim(2, by: "b")
        claims.claim(3, by: "a")
        #expect(claims.current == 3)
        claims.release("a")
        #expect(claims.current == 2)
    }
}

struct TrayRequestTests {
    private func element(_ x: Double, _ app: String, title: String? = nil, detail: String? = nil) -> TrayElement {
        TrayElement(frame: CGRect(x: x, y: 0, width: 30, height: 33), app: app, name: app, pid: 1, title: title, detail: detail)
    }

    @Test func `items seen in several menu bar windows merge keeping their labels`() {
        let items = TrayItem.merge([
            element(1300, "io.tailscale"), element(1065, "anomaly.hex"),
            element(1065, "anomaly.hex", detail: "Hex"), element(1300, "io.tailscale", title: ""),
        ])
        #expect(items.map(\.id) == ["anomaly.hex#1", "io.tailscale#1"])
        #expect(items[0].element.detail == "Hex")
        #expect(items[1].element.title == nil)
    }

    @Test func `ids count each apps items from left to right`() {
        let items = TrayItem.merge([
            element(1597, "com.apple.MenuBarAgent"),
            element(1443, "com.apple.MenuBarAgent"),
            element(1239, "com.brnbw.dinky", title: "2"),
        ])
        #expect(items.map(\.id) == ["com.brnbw.dinky#1", "com.apple.MenuBarAgent#1", "com.apple.MenuBarAgent#2"])
        #expect(items.map(\.element.frame.minX) == [1239, 1443, 1597])
        #expect(items[0].json(icon: nil)["title"] == .string("2"))
    }

    @Test func `an item with an icon is bounded by its ink and one without by its frame`() {
        let item = TrayItem.merge([element(1239, "com.brnbw.dinky", title: "3")])[0]
        let bounds = { (json: JSON) in ["x", "y", "width", "height"].map { json[$0] } }
        #expect(bounds(item.json(icon: nil)) == [1239, 0, 30, 33])
        let icon = TrayIcon(path: "/tmp/3.png", bounds: CGRect(x: 1250, y: 11.5, width: 7.5, height: 10))
        #expect(bounds(item.json(icon: icon)) == [1250, 11.5, 7.5, 10])
        #expect(item.json(icon: icon)["icon"] == .string("/tmp/3.png"))
    }

    @Test func `press takes an item ID and optionally A button and modifier keys`() throws {
        let id = JSON.string("com.brnbw.dinky#1")
        #expect(try TrayRequest.parse(call("tray", "press", id)) == .press(id: "com.brnbw.dinky#1", TrayClick()))
        #expect(try TrayRequest.parse(call("tray", "press", id, .null)) == .press(id: "com.brnbw.dinky#1", TrayClick()))
        #expect(try TrayRequest.parse(call("tray", "press", id, ["button": "right", "modifiers": ["alt", "cmd"]])) == .press(
            id: "com.brnbw.dinky#1",
            TrayClick(button: .right, modifiers: [.option, .command]),
        ))
        #expect(throws: ArgumentError("host.tray.press: id must be a string")) { try TrayRequest.parse(call("tray", "press")) }
        for options: JSON in [["button": "middle"], ["modifiers": "alt"], ["modifiers": ["option"]], "right"] {
            #expect(throws: ArgumentError.self) { try TrayRequest.parse(call("tray", "press", id, options)) }
        }
        #expect(throws: ArgumentError("host.tray.items is not a method")) { try TrayRequest.parse(call("tray", "items")) }
    }
}

struct AppsRequestTests {
    @Test func `each app method takes A bundle ID or an app path`() throws {
        let parsed = try ["launch", "activate", "quit"].map { try AppsRequest.parse(call("apps", $0, .string("com.apple.Calculator")), home: home) }
        #expect(parsed == [
            .launch(.bundle("com.apple.Calculator")),
            .activate(.bundle("com.apple.Calculator")),
            .quit(.bundle("com.apple.Calculator")),
        ])
        #expect(try AppsRequest
            .parse(call("apps", "launch", .string("/Applications/OrbStack.app/")), home: home) == .launch(.path("/Applications/OrbStack.app")))
        #expect(try AppsRequest
            .parse(call("apps", "quit", .string("~/Applications/Xcode.app")), home: home) == .quit(.path("/Users/gary/Applications/Xcode.app")))
        #expect(try AppsRequest.parse(call("apps", "installed"), home: home) == .installed)
    }

    @Test func `rejects what cannot be A bundle ID or an app path`() {
        for value in [JSON.string(""), .string("com apple"), .string("com.apple/../x"), .string("/Applications/notes.txt"), .number(1), .null] {
            #expect(throws: ArgumentError.self) { try AppsRequest.parse(call("apps", "launch", value), home: home) }
        }
        #expect(throws: ArgumentError("host.apps.hide is not a method")) {
            try AppsRequest.parse(call("apps", "hide", .string("com.apple.Calculator")), home: home)
        }
    }
}

struct DeviceRequestTests {
    @Test func `audio takes A fraction or flag and an optional scope`() throws {
        #expect(try AudioRequest.parse(call("audio", "setVolume", .number(0.4))) == .setVolume(0.4, .output))
        #expect(try AudioRequest.parse(call("audio", "setMuted", .bool(true), .string("input"))) == .setMuted(true, .input))
        #expect(try AudioRequest.parse(call("audio", "setDefaultDevice", .string("BuiltInSpeakerDevice"), .null)) == .setDefaultDevice(
            id: "BuiltInSpeakerDevice",
            .output,
        ))
        #expect(throws: ArgumentError("host.audio.setVolume: volume must be a number from 0 to 1")) { try AudioRequest.parse(call(
            "audio",
            "setVolume",
            .number(1.5),
        )) }
        #expect(throws: ArgumentError("host.audio.setMuted: scope must be \"output\" or \"input\"")) {
            try AudioRequest.parse(call("audio", "setMuted", .bool(false), .string("both")))
        }
        #expect(throws: ArgumentError("host.audio.setMuted: muted must be true or false")) { try AudioRequest.parse(call(
            "audio",
            "setMuted",
            .number(1),
        )) }
    }

    @Test func `audio sets an app's volume by process id`() throws {
        #expect(try AudioRequest.parse(call("audio", "setAppVolume", .number(4242), .number(0.3))) == .setAppVolume(pid: 4242, 0.3))
        for pid in [JSON.number(0), .number(-1), .number(1.5), .number(1e12), .string("4242")] {
            #expect(throws: ArgumentError.self) { try AudioRequest.parse(call("audio", "setAppVolume", pid, .number(0.3))) }
        }
        #expect(throws: ArgumentError("host.audio.setAppVolume: volume must be a number from 0 to 1")) {
            try AudioRequest.parse(call("audio", "setAppVolume", .number(4242), .number(2)))
        }
    }

    @Test func `brightness takes A fraction and an optional display`() throws {
        #expect(try BrightnessRequest.parse(call("brightness", "set", .number(0.5))) == .set(0.5, display: nil))
        #expect(try BrightnessRequest.parse(call("brightness", "set", .number(0), .string("37D8"))) == .set(0, display: "37D8"))
        #expect(throws: ArgumentError.self) { try BrightnessRequest.parse(call("brightness", "set", .number(-0.1))) }
        #expect(throws: ArgumentError("host.brightness.get is not a method")) { try BrightnessRequest.parse(call("brightness", "get")) }
    }

    @Test func `now playing seeks to A position and otherwise takes no arguments`() throws {
        #expect(try ["play", "pause", "toggle", "next", "previous"].map { try NowPlayingRequest.parse(call("nowplaying", $0)) } == [
            .play,
            .pause,
            .toggle,
            .next,
            .previous,
        ])
        #expect(try NowPlayingRequest.parse(call("nowplaying", "seek", .number(42.5))) == .seek(seconds: 42.5))
        #expect(throws: ArgumentError.self) { try NowPlayingRequest.parse(call("nowplaying", "seek", .number(-1))) }
        #expect(throws: ArgumentError.self) { try NowPlayingRequest.parse(call("nowplaying", "seek", .number(1e13))) }
        #expect(throws: ArgumentError.self) { try NowPlayingRequest.parse(call("nowplaying", "seek")) }
    }

    @Test func `notifications open takes A whole ID`() throws {
        #expect(try NotificationsRequest.parse(call("notifications", "open", .number(812))) == .open(id: 812))
        for value in [JSON.number(1.5), .number(-1), .string("812"), .null] {
            #expect(throws: ArgumentError.self) { try NotificationsRequest.parse(call("notifications", "open", value)) }
        }
    }

    @Test func `wifi and bluetooth take flags names and addresses`() throws {
        #expect(try WiFiRequest.parse(call("wifi", "setPower", .bool(false))) == .setPower(false))
        #expect(try WiFiRequest.parse(call("wifi", "join", .string("Home"))) == .join(ssid: "Home", password: nil))
        #expect(try WiFiRequest.parse(call("wifi", "join", .string("Home"), .string("secret"))) == .join(ssid: "Home", password: "secret"))
        #expect(try ["scan", "requestLocation"].map { try WiFiRequest.parse(call("wifi", $0)) } == [.scan, .requestLocation])
        #expect(throws: ArgumentError.self) { try WiFiRequest.parse(call("wifi", "join")) }
        #expect(try WiFiRequest.parse(call("wifi", "forget", .string("Home"))) == .forget(ssid: "Home"))
        #expect(throws: ArgumentError.self) { try WiFiRequest.parse(call("wifi", "forget")) }
        #expect(try BluetoothRequest.parse(call("bluetooth", "connect", .string("aa-bb-cc-dd-ee-ff"))) == .connect(address: "aa-bb-cc-dd-ee-ff"))
        #expect(try BluetoothRequest.parse(call("bluetooth", "setPower", .bool(true))) == .setPower(true))
        #expect(throws: ArgumentError("host.bluetooth.setPower: on must be true or false")) { try BluetoothRequest.parse(call(
            "bluetooth",
            "setPower",
            .string("on"),
        )) }
        #expect(try BluetoothRequest.parse(call("bluetooth", "discover", .bool(true))) == .discover(true))
        #expect(try BluetoothRequest.parse(call("bluetooth", "pair", .string("aa-bb-cc-dd-ee-ff"))) == .pair(address: "aa-bb-cc-dd-ee-ff"))
        #expect(throws: ArgumentError("host.bluetooth.unpair is not a method")) { try BluetoothRequest.parse(call(
            "bluetooth",
            "unpair",
            .string("aa"),
        )) }
    }
}
