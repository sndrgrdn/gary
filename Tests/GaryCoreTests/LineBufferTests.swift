import GaryCore
import Testing

struct LineBufferTests {
    @Test func `splits lines and holds the remainder`() {
        var buffer = LineBuffer(limit: 16, invalidUTF8: .reject)
        #expect(buffer.append(Array("a\nbc".utf8)) == [.text("a")])
        #expect(buffer.append(Array("d\n\ne\n".utf8)) == [.text("bcd"), .text(""), .text("e")])
        #expect(buffer.flush() == nil)
    }

    @Test func `joins A character split across reads`() {
        var buffer = LineBuffer(limit: 16, invalidUTF8: .reject)
        let bytes = Array("é\n".utf8)
        #expect(buffer.append(bytes[..<1]).isEmpty)
        #expect(buffer.append(bytes[1...]) == [.text("é")])
    }

    @Test func `rejects or replaces invalid UTF 8 as asked`() {
        var rejecting = LineBuffer(limit: 16, invalidUTF8: .reject)
        #expect(rejecting.append([0xFF, 10, 65, 10]) == [.invalidUTF8, .text("A")])
        var replacing = LineBuffer(limit: 16, invalidUTF8: .replace)
        #expect(replacing.append([0xFF, 10]) == [.text("\u{FFFD}")])
    }

    @Test func `cuts A line longer than the limit and drops the rest of it up to the next newline`() {
        var buffer = LineBuffer(limit: 4, invalidUTF8: .reject)
        #expect(buffer.append(Array("abcd\nab".utf8)) == [.text("abcd")])
        #expect(buffer.append(Array("cdef".utf8)) == [.tooLong("abcd")])
        #expect(buffer.append(Array("ghij".utf8)).isEmpty)
        #expect(buffer.append(Array("kl\nnext\n".utf8)) == [.text("next")])
        #expect(buffer.append(Array("abcdefgh\nz".utf8)) == [.tooLong("abcd")])
        #expect(buffer.flush() == .text("z"))
    }

    @Test func `breaks on A carriage return when asked and counts CR LF as one break across reads`() {
        var buffer = LineBuffer(limit: 32, invalidUTF8: .reject, breaksOnCarriageReturn: true)
        #expect(buffer.append(Array("\u{1B}[2K\rDownlink: 190 Mbps\rDownlink: 375".utf8)) == [.text("\u{1B}[2K"), .text("Downlink: 190 Mbps")])
        #expect(buffer.append(Array(" Mbps\r".utf8)) == [.text("Downlink: 375 Mbps")])
        #expect(buffer.append(Array("\nsummary\r\n\n".utf8)) == [.text("summary"), .text("")])
        var plain = LineBuffer(limit: 32, invalidUTF8: .reject)
        #expect(plain.append(Array("a\rb\n".utf8)) == [.text("a\rb")])
    }
}
