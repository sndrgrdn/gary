import Foundation

struct CommandError: Error, CustomStringConvertible {
    let description: String
    var usage = false
    init(_ description: String, usage: Bool = false) {
        self.description = description
        self.usage = usage
    }
}

struct Arguments {
    var positional: [String] = []
    var flags: Set<String> = []
    var options: [String: String] = [:]

    init(_ raw: [String], count: ClosedRange<Int>, flags allowed: Set<String> = [], options: Set<String> = []) throws {
        var rest = raw[...]
        while let argument = rest.popFirst() {
            if allowed.contains(argument) {
                flags.insert(argument)
            } else if options.contains(argument) {
                guard let value = rest.popFirst() else { throw CommandError("\(argument) needs a value", usage: true) }
                self.options[argument] = value
            } else if argument.hasPrefix("--") {
                throw CommandError("unknown option \(argument)", usage: true)
            } else {
                positional.append(argument)
            }
        }
        guard count.contains(positional.count) else { throw CommandError("wrong number of arguments", usage: true) }
    }
}
