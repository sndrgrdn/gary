import Foundation
@testable import GaryCore
import Testing

struct DeliveredNotificationRecordTests {
    private func record(_ text: String) -> Data {
        Data(#"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>\#(text)</dict></plist>"#.utf8)
    }

    @Test func `fields of the wrong type read as missing`() throws {
        let data = record("<key>app</key><integer>4</integer><key>date</key><integer>0</integer>"
            + "<key>req</key><dict><key>titl</key><true/><key>body</key><string>Hi</string></dict>")
        let notification = try #require(DeliveredNotification(id: 1, appColumn: "com.apple.shortcuts", record: data))
        #expect(notification == DeliveredNotification(
            id: 1, app: "com.apple.shortcuts", title: nil, subtitle: nil, body: "Hi", date: Date.timeIntervalBetween1970AndReferenceDate * 1000,
        ))
    }

    @Test func `a request or date of the wrong type skips the record`() {
        for fields in ["<key>date</key><real>1</real><key>req</key><string>x</string>", "<key>date</key><string>1</string><key>req</key><dict/>"] {
            #expect(DeliveredNotification(id: 1, appColumn: "a.b", record: record(fields)) == nil)
        }
    }
}
