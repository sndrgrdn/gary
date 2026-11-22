import Foundation

struct HostOptions {
    private let call: HostCall
    private let fields: [String: JSON]

    init(_ call: HostCall, keys: [String]) throws {
        guard let fields = call.arguments.first?.object else { throw call.fail("the argument must be an object") }
        if let unknown = fields.keys.sorted().first(where: { !keys.contains($0) }) {
            throw call.fail("unknown field \"\(unknown)\"; use " + keys.joined(separator: ", "))
        }
        self.call = call
        self.fields = fields
    }

    func string(_ key: String) throws -> String {
        guard let value = fields[key]?.string else { throw call.fail("\(key) must be a string") }
        return value
    }

    func optionalString(_ key: String) throws -> String? {
        guard let value = fields[key], value != .null else { return nil }
        guard let string = value.string else { throw call.fail("\(key) must be a string") }
        return string
    }

    func optionalNumber(_ key: String) throws -> Double? {
        guard let value = fields[key], value != .null else { return nil }
        guard let number = value.number, number.isFinite else { throw call.fail("\(key) must be a number") }
        return number
    }

    func optionalBool(_ key: String) throws -> Bool? {
        guard let value = fields[key], value != .null else { return nil }
        guard let bool = value.bool else { throw call.fail("\(key) must be true or false") }
        return bool
    }
}
