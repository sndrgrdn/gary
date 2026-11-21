import AppKit
import GaryCore
import GaryPrivate
import IOKit

extension Capability {
    static let brightness = Capability(
        name: "brightness",
        summary: "Brightness of the built-in display and of external displays that support DDC. Set it.",
        types: """
        declare namespace Gary {
          interface State { brightness?: Brightness }
          interface Brightness { displays: BrightnessDisplay[]; missing: string[] }
          interface BrightnessDisplay { id: string; name: string | null; builtin: boolean; brightness: number | null; control: "displayservices" | "ddc" | null }
          interface Host { brightness: BrightnessApi }
          interface BrightnessApi { set(value: number, display?: string | null): null }
        }
        """,
        example: """
        module.exports = {
          render(state) {
            return {
              type: "column",
              children: (state.brightness?.displays ?? []).filter((display) => display.brightness !== null).map((display) => (
                { type: "slider", key: display.id, value: display.brightness!, action: display.id }
              )),
            };
          },
          onAction(display, payload) {
            if (typeof payload === "number") host.brightness.set(payload, display);
          },
        } satisfies Gary.Panel;
        """,
        install: { host, plugin in
            plugin.installAPI(host, "brightness", BrightnessRequest.methods) { call in
                switch try BrightnessRequest.parse(call) {
                case let .set(value, id):
                    let displays = Display.online()
                    let target = id == nil ? displays.first(where: \.builtin) ?? displays.first : displays.first { $0.uuid == id }
                    guard let target else { throw HostFailure("no display \(id ?? "")") }
                    if let error = Panel.shared.set(value, on: target) {
                        throw HostFailure(error)
                    }
                    return .now(.null)
                }
            }
        },
        topic: { BrightnessTopic($0) },
    )
}

private enum DisplayServices {
    typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32
    typealias Register = @convention(c) (CGDirectDisplayID, UnsafeMutableRawPointer?, CFNotificationCallback) -> Int32
    typealias CreateAV = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    typealias AVTransfer = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    typealias DisplayInfo = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?

    static let get = privateSymbol(.getBrightness, as: Get.self)
    static let set = privateSymbol(.setBrightness, as: Set.self)
    static let register = privateSymbol(.registerBrightnessChanges, as: Register.self)
    static let createAV = privateSymbol(.avServiceCreate, as: CreateAV.self)
    static let readI2C = privateSymbol(.avServiceReadI2C, as: AVTransfer.self)
    static let writeI2C = privateSymbol(.avServiceWriteI2C, as: AVTransfer.self)
    static let displayInfo = privateSymbol(.displayInfo, as: DisplayInfo.self)

    static var missing: [String] {
        missingSymbols([
            .getBrightness,
            .setBrightness,
            .registerBrightnessChanges,
            .avServiceCreate,
            .avServiceReadI2C,
            .avServiceWriteI2C,
            .displayInfo,
        ])
    }

    static func location(_ display: CGDirectDisplayID) -> String? {
        guard let info = displayInfo?(display)?.takeRetainedValue() else { return nil }
        return (info as NSDictionary)[kIODisplayLocationKey] as? String
    }

    static func brightness(_ display: CGDirectDisplayID) -> Float? {
        var value: Float = -1
        guard let get, get(display, &value) == 0, value >= 0 else { return nil }
        return value
    }
}

private struct Display {
    let id: CGDirectDisplayID
    let uuid: String
    let builtin: Bool

    var label: String {
        builtin ? "the built-in display" : "display \(uuid)"
    }

    static func online() -> [Display] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).filter { CGDisplayIsActive($0) != 0 && CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }.compactMap { id in
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
            return Display(id: id, uuid: CFUUIDCreateString(nil, uuid) as String, builtin: CGDisplayIsBuiltin(id) != 0)
        }
    }
}

private struct ExternalPanel {
    let service: CFTypeRef
    var level: (current: UInt16, maximum: UInt16)?
}

private final class Panel {
    static let shared = Panel()
    let queue = DispatchQueue(label: "gary.brightness")
    private var external: [CGDirectDisplayID: ExternalPanel] = [:]

    func scan(_ displays: [Display]) {
        let services = avServices()
        external = [:]
        for display in displays where DisplayServices.brightness(display.id) == nil {
            guard let path = DisplayServices.location(display.id), let service = services[path] else { continue }
            external[display.id] = ExternalPanel(service: service, level: transfer(service, DDC.readRequest(DDC.brightness), reply: true))
        }
    }

    func snapshot(_ displays: [Display], names: [CGDirectDisplayID: String]) -> JSON {
        .object([
            "displays": .array(displays.map { display in
                var level: Double?
                var control: String?
                if let value = DisplayServices.brightness(display.id) {
                    (level, control) = (Double(value), "displayservices")
                } else if let panel = external[display.id] {
                    (level, control) = (panel.level.map { Double($0.current) / Double($0.maximum) }, "ddc")
                }
                return .object([
                    "id": .string(display.uuid), "name": names[display.id].map(JSON.string) ?? .null, "builtin": .bool(display.builtin),
                    "brightness": level.map { .number(($0 * 1000).rounded() / 1000) } ?? .null,
                    "control": control.map(JSON.string) ?? .null,
                ])
            }),
            "missing": .array(DisplayServices.missing.map(JSON.string)),
        ])
    }

    func set(_ level: Double, on display: Display) -> String? {
        if DisplayServices.brightness(display.id) != nil {
            guard let set = DisplayServices.set, set(display.id, Float(level)) == 0 else { return "cannot set the brightness of \(display.label)" }
            return nil
        }
        return queue.sync {
            guard let panel = external[display.id], let maximum = panel.level?.maximum else { return "\(display.label) has no brightness control" }
            let value = UInt16((level * Double(maximum)).rounded())
            queue.async { [self] in
                guard transfer(panel.service, DDC.writeRequest(DDC.brightness, value), reply: false) != nil
                else { return log("brightness: DDC write to \(display.label) failed") }
                external[display.id]?.level = (value, maximum)
                DispatchQueue.main.async { BrightnessTopic.current?.refresh(Trace("brightness-ddc")) }
            }
            return nil
        }
    }

    private func transfer(_ service: CFTypeRef, _ request: [UInt8], reply: Bool) -> (current: UInt16, maximum: UInt16)? {
        guard let read = DisplayServices.readI2C, let write = DisplayServices.writeI2C else { return nil }
        for _ in 0..<3 {
            var packet = request
            usleep(10000)
            guard write(service, UInt32(DDC.chipAddress), UInt32(DDC.dataAddress), &packet, UInt32(packet.count)) == kIOReturnSuccess
            else { continue }
            guard reply else { return (0, 1) }
            usleep(50000)
            var answer = [UInt8](repeating: 0, count: DDC.replyLength)
            if read(service, UInt32(DDC.chipAddress), 0, &answer, UInt32(answer.count)) == kIOReturnSuccess,
               let value = DDC.parseReply(answer, code: DDC.brightness)
            {
                return value
            }
            usleep(20000)
        }
        return nil
    }

    private func avServices() -> [String: CFTypeRef] {
        guard let create = DisplayServices.createAV else { return [:] }
        var iterator = io_iterator_t()
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS
        else { return [:] }
        defer { IOObjectRelease(iterator) }
        var services: [String: CFTypeRef] = [:]
        var framebuffer: String?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            var name = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(entry, &name)
            switch String(cString: name) {
            case "AppleCLCD2", "IOMobileFramebufferShim":
                var path = [CChar](repeating: 0, count: 1024)
                IORegistryEntryGetPath(entry, kIOServicePlane, &path)
                framebuffer = String(cString: path)
            case "DCPAVServiceProxy":
                guard let framebuffer,
                      IORegistryEntryCreateCFProperty(entry, "Location" as CFString, nil, 0)?.takeRetainedValue() as? String == "External",
                      let service = create(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }
                services[framebuffer] = service
            default:
                break
            }
        }
        return services
    }
}

private final class BrightnessTopic: TopicFeed {
    weak static var current: BrightnessTopic?
    private static var registered: Set<CGDirectDisplayID> = []
    private let publish: (JSON, Trace) -> Void
    private var observation: Observation?

    init(_ publish: @escaping (JSON, Trace) -> Void) {
        self.publish = publish
        Self.current = self
        observation = Observation(.default, NSApplication.didChangeScreenParametersNotification) { [weak self] in self?.refresh(
            Trace("screens"),
            scan: true,
        ) }
        refresh(Trace("brightness-start"), scan: true)
    }

    func refresh(_ trace: Trace, scan: Bool = false) {
        let displays = Display.online()
        let names = Dictionary(NSScreen.screens.compactMap { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { ($0.uint32Value, screen.localizedName) }
        }, uniquingKeysWith: { first, _ in first })
        for display in displays where DisplayServices.brightness(display.id) != nil && Self.registered.insert(display.id).inserted {
            _ = DisplayServices.register?(display.id, nil) { _, _, _, _, _ in
                DispatchQueue.main.async { BrightnessTopic.current?.refresh(Trace("brightness")) }
            }
        }
        let panel = Panel.shared
        panel.queue.async { [weak self] in
            if scan {
                panel.scan(displays)
            }
            let state = panel.snapshot(displays, names: names)
            self?.publish(state, trace)
        }
    }
}
