import Foundation
@testable import gary
import GaryCore
import Testing

struct AppsTests {
    @Test func `installed apps come from the folders, one level of subfolders, and named app bundles, with ids from binary and XML plists`() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "gary-apps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func app(_ path: String, id: String?, format: PropertyListSerialization.PropertyListFormat = .binary) throws {
            let contents = root.appending(path: "\(path)/Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            guard let id else { return }
            let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id], format: format, options: 0)
            try data.write(to: contents.appending(path: "Info.plist"))
        }
        try app("Applications/OrbStack.app", id: "dev.kdrag0n.MacVirt")
        try app("Applications/Utilities/Console.app", id: "com.apple.Console", format: .xml)
        try app("Applications/Utilities/Deeper/Hidden.app", id: "com.example.hidden")
        try app("Applications/Bare.app", id: nil)
        try app("Home/OrbStack.app", id: "dev.kdrag0n.MacVirt")
        try app("Home/WhatsApp.app", id: "net.whatsapp.WhatsApp")
        try app("CoreServices/Finder.app", id: "com.apple.finder")
        try app("CoreServices/Agent.app", id: "com.apple.agent")
        try Data().write(to: root.appending(path: "Applications/notes.txt"))

        let apps = installedApps(in: [
            root.appending(path: "Applications").path,
            root.appending(path: "Home").path,
            root.appending(path: "Missing").path,
            root.appending(path: "CoreServices/Finder.app").path,
            root.appending(path: "CoreServices/Missing.app").path,
        ])

        #expect(apps.map { $0["name"]?.string } == ["Bare", "Console", "Finder", "OrbStack", "WhatsApp"])
        #expect(apps.map { $0["app"] } == [
            .null,
            .string("com.apple.Console"),
            .string("com.apple.finder"),
            .string("dev.kdrag0n.MacVirt"),
            .string("net.whatsapp.WhatsApp"),
        ])
        #expect(apps[3]["path"] == .string(root.appending(path: "Applications/OrbStack.app").path))
    }
}
