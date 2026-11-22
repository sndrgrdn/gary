import Foundation
@testable import GaryCore
import Testing

struct JSONTests {
    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func `a non finite number encodes as null`(_ value: Double) {
        #expect(JSON.object(["x": .number(value)]).text == #"{"x":null}"#)
    }

    @Test(arguments: [
        (1.0, "1"), (-5, "-5"), (-0.0, "-0"), (0.1, "0.1"), (1.5e-7, "1.5e-07"), (1e15, "1000000000000000"),
        (9_007_199_254_740_992, "9007199254740992"), (9_007_199_254_740_994, "9.007199254740994e+15"), (1e21, "1e+21"),
        (3.000_000_000_000_000_4, "3.0000000000000004"),
    ])
    func `numbers print without a trailing zero and keep round trip precision`(_ value: Double, _ text: String) throws {
        #expect(JSON.number(value).text == text)
        #expect(try JSON.parse(text) == .number(value))
    }

    @Test func `strings escape quotes, backslashes and control characters and keep other text`() throws {
        let value = JSON.string("a\"b\\c\n\t\r\u{8}\u{C}\u{1}\u{1F}/\u{7F}é😀\u{2028}")
        #expect(value.text == #""a\"b\\c\n\t\r\b\f\u0001\u001f/\#u{7F}é😀\#u{2028}""#)
        #expect(try JSON.parse(value.text) == value)
    }

    @Test(arguments: [
        (#"[1,]"#, JSON.array([1])), (#"{"a":1,}"#, ["a": 1]), (#"{"a":1,"a":2}"#, ["a": 1]), ("\u{FEFF}[true]", [true]),
        (#" {"a" : [null, -0.5e2] } "#, ["a": [.null, -50]]), (#""\u00e9\uD83D\uDE00\/""#, "é😀/"),
        ("12345678901234567890", 12_345_678_901_234_567_890.0),
    ] as [(String, JSON)])
    func `parse reads JSON with trailing commas, a byte order mark and the first of duplicate keys`(_ text: String, _ value: JSON) throws {
        #expect(try JSON.parse(text) == value)
        #expect(try JSON.parse(Data(text.utf8)) == value)
    }

    @Test(arguments: [
        "", " ", "[01]", "[1.]", "[.5]", "1e400", "1e-400", "-", "[,]", "[1,,]", "{,}", "[1]]", "1 2", "tru", "nulll", "[true false]",
        #""\uDE00""#, #""\uD800x""#, "\"a\tb\"", #""\q""#, #"{"a"}"#, #"{1:2}"#, "\"open", "[[1]",
        String(repeating: "[", count: 513) + String(repeating: "]", count: 513),
    ])
    func `parse rejects text that is not JSON`(_ text: String) {
        #expect {
            try JSON.parse(text)
        } throws: { error in
            (error as? JSON.ParseError)?.description.hasPrefix("invalid JSON: ") == true
        }
    }

    @Test func `parse reads arrays nested 512 deep`() throws {
        let text = String(repeating: "[", count: 512) + String(repeating: "]", count: 512)
        #expect(try JSON.parse(text).text == text)
    }

    @Test func `parse rejects bytes that are not UTF-8`() {
        #expect(throws: JSON.ParseError.self) { try JSON.parse(Data([0x22, 0xFF, 0x22])) }
    }
}
