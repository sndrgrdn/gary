import Foundation
import Testing
@testable import GaryCore

private let home = "/Users/gary"

private func call(_ api: String?, _ method: String, _ arguments: JSON...) -> HostCall {
    HostCall(api: api, method: method, arguments: arguments)
}

struct HostCallTests {
    @Test func pathsAreAbsoluteOrHomeRelativeAndComeBackNormalised() {
        #expect(absolutePath("~", home: home) == "/Users/gary")
        #expect(absolutePath("~/notes/../clips/a.txt", home: home) == "/Users/gary/clips/a.txt")
        #expect(absolutePath("/tmp//gary/./x", home: home) == "/tmp/gary/x")
        #expect(absolutePath("notes.txt", home: home) == nil)
        #expect(absolutePath("~other/notes.txt", home: home) == nil)
        #expect(absolutePath("", home: home) == nil)
    }

    @Test func errorsNameTheHostFunctionThePluginCalled() {
        #expect(call("dock", "reserve").fail("size must be a number").description == "host.dock.reserve: size must be a number")
        #expect(call(nil, "writeFile").unknownMethod.description == "host.writeFile is not a method")
    }
}

struct FilesRequestTests {
    @Test func eachMethodTakesAPathAndWriteFileTakesText() throws {
        #expect(try FilesRequest.parse(call(nil, "readFile", .string("~/a.txt")), home: home) == .read(path: "/Users/gary/a.txt"))
        #expect(try FilesRequest.parse(call(nil, "writeFile", .string("/tmp/a.txt"), .string("hi")), home: home) == .write(path: "/tmp/a.txt", text: "hi"))
        #expect(try FilesRequest.parse(call(nil, "mkdir", .string("~/cache/clips")), home: home) == .makeDirectory(path: "/Users/gary/cache/clips"))
        #expect(try FilesRequest.parse(call(nil, "remove", .string("~/cache/clips")), home: home) == .remove(path: "/Users/gary/cache/clips"))
        #expect(try FilesRequest.parse(call(nil, "list", .string("/tmp")), home: home) == .list(path: "/tmp"))
    }

    @Test func rejectsRelativePathsMissingTextAndUnknownMethods() {
        #expect(throws: ArgumentError("host.readFile: path \"notes.txt\" must be absolute or start with ~/")) {
            try FilesRequest.parse(call(nil, "readFile", .string("notes.txt")), home: home)
        }
        #expect(throws: ArgumentError("host.writeFile: text must be a string")) {
            try FilesRequest.parse(call(nil, "writeFile", .string("/tmp/a.txt")), home: home)
        }
        #expect(throws: ArgumentError.self) { try FilesRequest.parse(call(nil, "list", .number(3)), home: home) }
        #expect(throws: ArgumentError("host.chmod is not a method")) { try FilesRequest.parse(call(nil, "chmod", .string("/tmp")), home: home) }
    }

    @Test func removeRefusesTheRootAndTheHomeFolder() {
        for raw in ["/", "~", "~/", "/Users/gary/."] {
            #expect(throws: ArgumentError.self) { try FilesRequest.parse(call(nil, "remove", .string(raw)), home: home) }
        }
    }
}

struct ClipboardRequestTests {
    @Test func readTakesNothingAndWriteTextTakesAString() throws {
        #expect(try ClipboardRequest.parse(call("clipboard", "read")) == .read)
        #expect(try ClipboardRequest.parse(call("clipboard", "writeText", .string("hello"))) == .writeText("hello"))
        #expect(throws: ArgumentError("host.clipboard.writeText: text must be a string")) {
            try ClipboardRequest.parse(call("clipboard", "writeText", .number(5)))
        }
        #expect(throws: ArgumentError.self) { try ClipboardRequest.parse(call("clipboard", "clear")) }
    }
}

struct WallpaperRequestTests {
    @Test func setTakesAnImagePathAndAnOptionalDisplay() throws {
        #expect(try WallpaperRequest.parse(call("wallpaper", "get"), home: home) == .get)
        #expect(try WallpaperRequest.parse(call("wallpaper", "set", .string("~/Pictures/a.png")), home: home)
            == .set(path: "/Users/gary/Pictures/a.png", display: nil))
        #expect(try WallpaperRequest.parse(call("wallpaper", "set", .string("/a.png"), .null), home: home) == .set(path: "/a.png", display: nil))
        #expect(try WallpaperRequest.parse(call("wallpaper", "set", .string("/a.png"), .string("37D8")), home: home) == .set(path: "/a.png", display: "37D8"))
        #expect(throws: ArgumentError.self) { try WallpaperRequest.parse(call("wallpaper", "set", .string("a.png")), home: home) }
        #expect(throws: ArgumentError("host.wallpaper.set: display must be a string")) {
            try WallpaperRequest.parse(call("wallpaper", "set", .string("/a.png"), .number(0)), home: home)
        }
    }
}

struct AppsRequestTests {
    @Test func eachMethodTakesABundleID() throws {
        let parsed = try AppsRequest.methods.map { try AppsRequest.parse(call("apps", $0, .string("com.apple.Calculator"))) }
        #expect(parsed == [.launch(bundle: "com.apple.Calculator"), .activate(bundle: "com.apple.Calculator"), .quit(bundle: "com.apple.Calculator")])
    }

    @Test func rejectsWhatCannotBeABundleID() {
        for value in [JSON.string(""), .string("com apple"), .string("com.apple/../x"), .number(1), .null] {
            #expect(throws: ArgumentError.self) { try AppsRequest.parse(call("apps", "launch", value)) }
        }
        #expect(throws: ArgumentError("host.apps.hide is not a method")) { try AppsRequest.parse(call("apps", "hide", .string("com.apple.Calculator"))) }
    }
}
