import Foundation

public enum TrayRequest: Equatable, Sendable {
    case items
    case press(id: String)

    public static let methods = ["items", "press"]

    public static func parse(_ call: HostCall) throws -> TrayRequest {
        switch call.method {
        case "items": .items
        case "press": try .press(id: call.string(0, "id"))
        default: throw call.unknownMethod
        }
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

    public func json(icon: String?) -> JSON {
        let frame = element.frame
        return .object([
            "id": .string(id),
            "app": .string(element.app),
            "name": .string(element.name),
            "pid": .number(Double(element.pid)),
            "title": element.title.map(JSON.string) ?? .null,
            "description": element.detail.map(JSON.string) ?? .null,
            "x": .number(frame.minX), "y": .number(frame.minY), "width": .number(frame.width), "height": .number(frame.height),
            "icon": icon.map(JSON.string) ?? .null,
        ])
    }
}
