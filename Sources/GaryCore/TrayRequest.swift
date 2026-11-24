import Foundation

public enum TrayButton: String, CaseIterable, Sendable {
    case left, right
}

public struct TrayClick: Equatable, Sendable {
    public var button: TrayButton
    public var modifiers: KeyModifiers

    public init(button: TrayButton = .left, modifiers: KeyModifiers = []) {
        self.button = button
        self.modifiers = modifiers
    }
}

public enum TrayRequest: Equatable, Sendable {
    case press(id: String, TrayClick)

    public static let methods = ["press"]

    public static func parse(_ call: HostCall) throws -> TrayRequest {
        guard call.method == "press" else { throw call.unknownMethod }
        let id = try call.string(0, "id")
        guard call.arguments.count > 1, call.arguments[1] != .null else { return .press(id: id, TrayClick()) }
        guard let options = call.arguments[1].object else { throw call.fail("options must be an object") }
        var click = TrayClick()
        if let raw = options["button"] {
            guard let button = raw.string.flatMap(TrayButton.init(rawValue:)) else { throw call.fail("button must be \"left\" or \"right\"") }
            click.button = button
        }
        if let raw = options["modifiers"] {
            let names = raw.array ?? [.null]
            let modifiers = names.compactMap { name in KeyModifiers.names.first { $0.name == name.string }?.modifier }
            guard modifiers.count == names.count else { throw call.fail("modifiers must be an array of \"cmd\", \"ctrl\", \"alt\" and \"shift\"") }
            click.modifiers = KeyModifiers(modifiers)
        }
        return .press(id: id, click)
    }
}

public struct TrayElement: Equatable, Sendable {
    public var frame: CGRect
    public var app: String
    public var name: String
    public var pid: Int32
    public var title: String?
    public var detail: String?

    public init(frame: CGRect, app: String, name: String, pid: Int32, title: String? = nil, detail: String? = nil) {
        self.frame = frame
        self.app = app
        self.name = name
        self.pid = pid
        self.title = title?.isEmpty == true ? nil : title
        self.detail = detail?.isEmpty == true ? nil : detail
    }

    var labels: Int {
        (title == nil ? 0 : 1) + (detail == nil ? 0 : 1)
    }
}

public struct TrayIcon: Equatable, Sendable {
    public var path: String
    public var bounds: CGRect

    public init(path: String, bounds: CGRect) {
        self.path = path
        self.bounds = bounds
    }
}

public struct TrayItem: Equatable, Sendable {
    public let id: String
    public let element: TrayElement

    public static func merge(_ elements: [TrayElement]) -> [TrayItem] {
        var slots: [Int: TrayElement] = [:]
        for element in elements {
            let slot = Int(element.frame.minX.rounded())
            if let kept = slots[slot], kept.labels >= element.labels {
                continue
            }
            slots[slot] = element
        }
        var counts: [String: Int] = [:]
        return slots.sorted { $0.key < $1.key }.map { _, element in
            let count = counts[element.app, default: 0] + 1
            counts[element.app] = count
            return TrayItem(id: "\(element.app)#\(count)", element: element)
        }
    }

    public func json(icon: TrayIcon?) -> JSON {
        let frame = icon?.bounds ?? element.frame
        return .object([
            "id": .string(id),
            "app": .string(element.app),
            "name": .string(element.name),
            "pid": .number(Double(element.pid)),
            "title": element.title.map(JSON.string) ?? .null,
            "description": element.detail.map(JSON.string) ?? .null,
            "x": .number(frame.minX), "y": .number(frame.minY), "width": .number(frame.width), "height": .number(frame.height),
            "icon": icon.map { .string($0.path) } ?? .null,
        ])
    }
}

public struct AppStalls: Sendable {
    public static let backoff: TimeInterval = 30
    private var until: [Int32: TimeInterval]

    public init() {
        until = [:]
    }

    public func asks(_ pid: Int32, at now: TimeInterval) -> Bool {
        until[pid].map { now >= $0 } ?? true
    }

    public mutating func timedOut(_ pid: Int32, at now: TimeInterval) {
        until = until.filter { now < $0.value }
        until[pid] = now + Self.backoff
    }
}
