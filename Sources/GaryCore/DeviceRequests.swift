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
        case "setVolume": return .setVolume(try call.fraction(0, "volume"), try scope())
        case "setMuted": return .setMuted(try call.bool(0, "muted"), try scope())
        case "setDefaultDevice": return .setDefaultDevice(id: try call.string(0, "id"), try scope())
        default: throw call.unknownMethod
        }
    }
}

public enum BrightnessRequest: Equatable, Sendable {
    case set(Double, display: String?)

    public static let methods = ["set"]

    public static func parse(_ call: HostCall) throws -> BrightnessRequest {
        guard call.method == "set" else { throw call.unknownMethod }
        return .set(try call.fraction(0, "brightness"), display: try call.optionalString(1, "display"))
    }
}

public enum MediaKeysRequest: Equatable, Sendable {
    case intercept(Set<MediaKey>)

    public static let methods = ["intercept"]

    public static func parse(_ call: HostCall) throws -> MediaKeysRequest {
        guard call.method == "intercept" else { throw call.unknownMethod }
        do {
            return .intercept(try MediaKey.parse(try call.strings(0, "keys")))
        } catch let error as MediaKey.UnknownKey {
            throw call.fail(error.description)
        }
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
            guard seconds >= 0 else { throw call.fail("seconds must be 0 or more") }
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
        case "setPower": return .setPower(try call.bool(0, "on"))
        case "scan": return .scan
        case "join": return .join(ssid: try call.string(0, "ssid"), password: try call.optionalString(1, "password"))
        case "requestLocation": return .requestLocation
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
        case "setPower": return .setPower(try call.bool(0, "on"))
        case "connect": return .connect(address: try call.string(0, "address"))
        case "disconnect": return .disconnect(address: try call.string(0, "address"))
        case "requestAccess": return .requestAccess
        default: throw call.unknownMethod
        }
    }
}
