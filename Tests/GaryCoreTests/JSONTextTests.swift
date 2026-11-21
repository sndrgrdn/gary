import Foundation
@testable import GaryCore
import Testing

struct JSONTextTests {
    @Test func `text sorts keys and keeps slashes and pretty text indents and ends with a newline`() {
        let value = JSON.object(["b": .string("a/b"), "a": .array([.number(1), .bool(true), .null])])
        #expect(value.text == #"{"a":[1,true,null],"b":"a/b"}"#)
        #expect(value.encoded() == Data(value.text.utf8))
        #expect(value.prettyText == """
        {
          "a" : [
            1,
            true,
            null
          ],
          "b" : "a/b"
        }

        """)
    }
}
