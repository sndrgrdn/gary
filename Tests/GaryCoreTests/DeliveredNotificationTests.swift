import Foundation
@testable import GaryCore
import Testing

struct DeliveredNotificationTests {
    static func record(_ fields: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: fields, format: .binary, options: 0)
    }

    @Test func `a usernoted record gives the app text and epoch date`() throws {
        let data = try Self.record([
            "app": "com.apple.ScriptEditor2", "date": 816_958_292.5, "intl": true, "styl": 1,
            "req": ["titl": "Build finished", "subt": "gary", "body": "All tests passed", "dest": 7],
        ])
        let notification = try #require(DeliveredNotification(id: 3, appColumn: "com.apple.scripteditor2", record: data))
        #expect(notification == DeliveredNotification(
            id: 3, app: "com.apple.ScriptEditor2", title: "Build finished", subtitle: "gary", body: "All tests passed", date: 1_795_265_492_500,
        ))
    }

    @Test func `missing text fields stay empty and the app falls back to the table`() throws {
        let data = try Self.record(["date": 816_958_292.0, "req": ["body": "Only a body"]])
        let notification = try #require(DeliveredNotification(id: 9, appColumn: "com.apple.shortcuts", record: data))
        #expect(notification.app == "com.apple.shortcuts")
        #expect(notification.title == nil)
        #expect(notification.subtitle == nil)
        #expect(notification.body == "Only a body")
    }

    @Test func `a record without A request or date or that is not A plist is skipped`() throws {
        #expect(try DeliveredNotification(id: 1, appColumn: "a.b", record: Self.record(["date": 1.0])) == nil)
        #expect(try DeliveredNotification(id: 1, appColumn: "a.b", record: Self.record(["req": ["titl": "x"]])) == nil)
        #expect(DeliveredNotification(id: 1, appColumn: "a.b", record: Data("not a plist".utf8)) == nil)
    }
}
