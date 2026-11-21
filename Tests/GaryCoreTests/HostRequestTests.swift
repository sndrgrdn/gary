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
