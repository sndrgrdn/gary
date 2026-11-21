@testable import GaryCore
import Testing

struct DDCTests {
    @Test func `a brightness read asks for VCP 10 with the checksum monitors accept`() {
        #expect(DDC.readRequest(0x10) == [0x82, 0x01, 0x10, 0xFD])
    }

    @Test func `a brightness write carries the value big endian`() {
        #expect(DDC.writeRequest(0x10, 0x0132) == [0x84, 0x03, 0x10, 0x01, 0x32, 0x9B])
    }

    @Test func `a valid reply gives the current and maximum value`() throws {
        let reply = Self.reply(code: 0x10, maximum: 100, current: 63)
        let value = try #require(DDC.parseReply(reply, code: 0x10))
        #expect(value.current == 63)
        #expect(value.maximum == 100)
    }

    @Test func `a reply is rejected when its checksum result code or feature is wrong`() {
        var corrupt = Self.reply(code: 0x10, maximum: 100, current: 63)
        corrupt[9] ^= 0x01
        #expect(DDC.parseReply(corrupt, code: 0x10) == nil)
        #expect(DDC.parseReply(Self.reply(code: 0x10, maximum: 100, current: 63, result: 0x01), code: 0x10) == nil)
        #expect(DDC.parseReply(Self.reply(code: 0x12, maximum: 100, current: 63), code: 0x10) == nil)
        #expect(DDC.parseReply(Self.reply(code: 0x10, maximum: 0, current: 0), code: 0x10) == nil)
        #expect(DDC.parseReply([0x6E, 0x88], code: 0x10) == nil)
    }

    private static func reply(code: UInt8, maximum: UInt16, current: UInt16, result: UInt8 = 0) -> [UInt8] {
        let body: [UInt8] = [
            0x6E,
            0x88,
            0x02,
            result,
            code,
            0x00,
            UInt8(maximum >> 8),
            UInt8(maximum & 0xFF),
            UInt8(current >> 8),
            UInt8(current & 0xFF),
        ]
        return body + [body.reduce(0x50, ^)]
    }
}
