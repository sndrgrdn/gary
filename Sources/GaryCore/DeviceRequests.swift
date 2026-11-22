import Foundation

public enum AudioScope: String, CaseIterable, Sendable {
    case output, input
}

public enum AudioRequest: Equatable, Sendable {
    case setVolume(Double, AudioScope)
    case setMuted(Bool, AudioScope)
    case setDefaultDevice(id: String, AudioScope)

    public static let methods = ["setVolume", "setMuted", "setDefaultDevice"]

    public static func parse(_ call: HostCall) throws -> AudioRequest {
        let scope = { try call.choice(1, "scope", default: AudioScope.output) }
        switch call.method {
        case "setVolume": return try .setVolume(call.fraction(0, "volume"), scope())
        case "setMuted": return try .setMuted(call.bool(0, "muted"), scope())
        case "setDefaultDevice": return try .setDefaultDevice(id: call.string(0, "id"), scope())
        default: throw call.unknownMethod
        }
    }
}

public enum BrightnessRequest: Equatable, Sendable {
    case set(Double, display: String?)

    public static let methods = ["set"]

    public static func parse(_ call: HostCall) throws -> BrightnessRequest {
        guard call.method == "set" else { throw call.unknownMethod }
        return try .set(call.fraction(0, "brightness"), display: call.optionalString(1, "display"))
    }
}

public enum NowPlayingRequest: Equatable, Sendable {
    case play, pause, toggle, next, previous
    case seek(seconds: Double)

    public static let methods = ["play", "pause", "toggle", "next", "previous", "seek"]

    public static func parse(_ call: HostCall) throws -> NowPlayingRequest {
        switch call.method {
        case "play": return .play
        case "pause": return .pause
        case "toggle": return .toggle
        case "next": return .next
        case "previous": return .previous
        case "seek":
            let seconds = try call.number(0, "seconds")
            guard (0...1e9).contains(seconds) else { throw call.fail("seconds must be from 0 to 1e9") }
            return .seek(seconds: seconds)
        default: throw call.unknownMethod
        }
    }
}

public enum NotificationsRequest: Equatable, Sendable {
    case open(id: Int)

    public static let methods = ["open"]

    public static func parse(_ call: HostCall) throws -> NotificationsRequest {
        guard call.method == "open" else { throw call.unknownMethod }
        let id = try call.number(0, "id")
        guard id >= 0, id == id.rounded(), id < 1e15 else { throw call.fail("id must be a notification id") }
        return .open(id: Int(id))
    }
}

public enum WiFiRequest: Equatable, Sendable {
    case setPower(Bool)
    case scan
    case join(ssid: String, password: String?)
    case requestLocation

    public static let methods = ["setPower", "scan", "join", "requestLocation"]

    public static func parse(_ call: HostCall) throws -> WiFiRequest {
        switch call.method {
        case "setPower": try .setPower(call.bool(0, "on"))
        case "scan": .scan
        case "join": try .join(ssid: call.string(0, "ssid"), password: call.optionalString(1, "password"))
        case "requestLocation": .requestLocation
        default: throw call.unknownMethod
        }
    }
}

public enum BluetoothRequest: Equatable, Sendable {
    case setPower(Bool)
    case connect(address: String)
    case disconnect(address: String)
    case requestAccess

    public static let methods = ["setPower", "connect", "disconnect", "requestAccess"]

    public static func parse(_ call: HostCall) throws -> BluetoothRequest {
        switch call.method {
        case "setPower": try .setPower(call.bool(0, "on"))
        case "connect": try .connect(address: call.string(0, "address"))
        case "disconnect": try .disconnect(address: call.string(0, "address"))
        case "requestAccess": .requestAccess
        default: throw call.unknownMethod
        }
    }
}
