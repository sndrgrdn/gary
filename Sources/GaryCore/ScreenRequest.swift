import Foundation

public enum ScreenArea: Equatable, Sendable {
    case display(String?)
    case window(UInt32)
    case region(CGRect)

    static func parse(_ value: JSON?, _ call: HostCall) throws -> ScreenArea {
        let shape = "area must be { display }, { window }, or { x, y, width, height }"
        guard let fields = value?.object else { throw call.fail(shape) }
        switch Set(fields.keys) {
        case [], ["display"]:
            guard let display = fields["display"], display != .null else { return .display(nil) }
            guard let id = display.string else { throw call.fail("area.display must be a display id") }
            return .display(id)
        case ["window"]:
            guard let id = fields["window"]?.number, id >= 0, id <= Double(UInt32.max), id == id.rounded() else {
                throw call.fail("area.window must be a window number")
            }
            return .window(UInt32(id))
        case ["x", "y", "width", "height"]:
            let numbers = ["x", "y", "width", "height"].compactMap { fields[$0]?.number }.filter(\.isFinite)
            guard numbers.count == 4 else { throw call.fail("area x, y, width, and height must be numbers") }
            guard numbers[2] >= 1, numbers[3] >= 1 else { throw call.fail("area width and height must be at least 1") }
            return .region(CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]))
        default:
            throw call.fail(shape)
        }
    }

    public var json: JSON {
        switch self {
        case let .display(id): .object(["display": id.map(JSON.string) ?? .null])
        case let .window(id): .object(["window": .number(Double(id))])
        case let .region(rect):
            .object(["x": .number(rect.minX), "y": .number(rect.minY), "width": .number(rect.width), "height": .number(rect.height)])
        }
    }
}

public enum ScreenRequest: Equatable, Sendable {
    case select
    case capture(ScreenArea, path: String?, clipboard: Bool)

    public static let methods = ["select", "capture"]

    public static func parse(_ call: HostCall, home: String, folder: String) throws -> ScreenRequest {
        switch call.method {
        case "select": return .select
        case "capture":
            let area = try ScreenArea.parse(call.arguments.first, call)
            let options = call.arguments.count > 1 ? call.arguments[1] : .null
            guard options == .null || options.object != nil else { throw call.fail("options must be an object") }
            var path: String?
            if let raw = options["path"], raw != .null {
                guard let text = raw.string, let absolute = absolutePath(text, home: home, folder: folder) else {
                    throw call.fail("options.path must be absolute, start with ~/, or be relative to the plugin folder")
                }
                path = absolute
            }
            let clipboard = options["clipboard"] ?? .bool(false)
            guard let copy = clipboard.bool else { throw call.fail("options.clipboard must be true or false") }
            return .capture(area, path: path, clipboard: copy)
        default: throw call.unknownMethod
        }
    }
}
