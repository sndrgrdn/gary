@testable import GaryCore
import Testing

struct NodeReaderTests {
    @Test(arguments: Node.Kind.allCases)
    func `every kind parses from its type name`(_ kind: Node.Kind) throws {
        let fields = #""text":"t","symbol":"s","path":"/p","value":0.5"#
        #expect(try Node.parse(JSON.parse(#"{"type":"\#(kind.rawValue)",\#(fields)}"#)).kind == kind)
    }

    @Test func `numbers in text and value read as whole numbers when they are whole and small`() throws {
        func text(_ number: String) throws -> Node.Content {
            try Node.parse(JSON.parse(#"{"type":"text","text":\#(number)}"#)).content
        }
        #expect(try text("42") == .text("42"))
        #expect(try text("-3") == .text("-3"))
        #expect(try text("1.5") == .text("1.5"))
        #expect(try text("1e15") == .text("1000000000000000.0"))
        #expect(try Node.parse(JSON.parse(#"{"type":"input","value":7}"#)).content == .input(Node.Input(value: "7")))
        #expect(throws: NodeError(path: "root", reason: "key must be a string")) { try Node.parse(JSON.parse(#"{"type":"spacer","key":1}"#)) }
    }

    @Test func `each gesture reads its action from its own field`() throws {
        let node = try Node.parse(JSON.parse(#"""
        {"type":"text","text":"a","action":"open","rightAction":"menu","middleAction":"close","scrollAction":"volume"}
        """#))
        #expect(node.actions == [.click: "open", .rightClick: "menu", .middleClick: "close", .scroll: "volume"])
        #expect(try Node.parse(JSON.parse(#"{"type":"spacer","rightAction":null}"#)).actions.isEmpty)
        #expect(throws: NodeError(path: "root", reason: "scrollAction must be a string")) {
            try Node.parse(JSON.parse(#"{"type":"spacer","scrollAction":1}"#))
        }
    }
}
