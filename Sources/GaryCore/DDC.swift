import Foundation

public enum DDC {
    public static let chipAddress: UInt8 = 0x37
    public static let dataAddress: UInt8 = 0x51
    public static let brightness: UInt8 = 0x10
    public static let replyLength = 11

    public static func readRequest(_ code: UInt8) -> [UInt8] {
        sealed([0x82, 0x01, code], seed: chipAddress << 1)
    }

    public static func writeRequest(_ code: UInt8, _ value: UInt16) -> [UInt8] {
        sealed([0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF)], seed: chipAddress << 1 ^ dataAddress)
    }

    public static func parseReply(_ reply: [UInt8], code: UInt8) -> (current: UInt16, maximum: UInt16)? {
        guard reply.count == replyLength, reply[0..<10].reduce(0x50, ^) == reply[10],
              reply[2] == 0x02, reply[3] == 0x00, reply[4] == code else { return nil }
        let maximum = UInt16(reply[6]) << 8 | UInt16(reply[7])
        guard maximum > 0 else { return nil }
        return (UInt16(reply[8]) << 8 | UInt16(reply[9]), maximum)
    }

    private static func sealed(_ bytes: [UInt8], seed: UInt8) -> [UInt8] {
        bytes + [bytes.reduce(seed, ^)]
    }
}
