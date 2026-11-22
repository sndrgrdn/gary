import Foundation
@testable import gary
import Testing

struct ClockTests {
    @Test func `reads 12-hour time from the locale's region`() {
        #expect(Locale(identifier: "en_US").hour12)
        #expect(!Locale(identifier: "en_US@rg=nlzzzz").hour12)
        #expect(!Locale(identifier: "en_NL").hour12)
    }

    @Test func `reads 12-hour time from patterns without an AM marker and 24-hour time past quoted text`() {
        #expect(Locale(identifier: "zh_Hant_TW").hour12)
        #expect(!Locale(identifier: "de_DE").hour12)
        #expect(!Locale(identifier: "fr_FR").hour12)
    }
}
