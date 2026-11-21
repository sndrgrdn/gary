import CoreBluetooth
import GaryCore
import GaryPrivate
import IOBluetooth
import IOKit
import JavaScriptCore

extension Capability {
    static let bluetooth = Capability(name: "bluetooth", types: """
    declare namespace Gary {
      interface State { bluetooth?: Bluetooth }
      interface Bluetooth {
        available: boolean;
        permission: "allowed" | "denied" | "restricted" | "notDetermined";
        power: boolean | null;
        devices: BluetoothDevice[];
        missing: string[];
      }
      interface BluetoothDevice { address: string; name: string | null; connected: boolean; battery: number | null }
      interface Host { bluetooth: BluetoothApi }
      interface BluetoothApi {
        setPower(on: boolean): void;
        connect(address: string): Promise<"connected">;
        disconnect(address: string): Promise<"disconnected">;
        requestAccess(): void;
      }
    }
    """, permissions: [.bluetooth], install: { host, plugin in
        let setPower: @convention(block) (Bool) -> Void = { on in
            guard CBManager.authorization == .allowedAlways else { return JSValue.fail("Gary needs Bluetooth permission") }
            guard let set = BluetoothPower.set else { return JSValue.fail("IOBluetoothPreferenceSetControllerPowerState is missing on this macOS") }
            set(on ? 1 : 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { BluetoothTopic.current?.send(Trace("bluetooth-power")) }
        }
        let connect: @convention(block) (String) -> JSValue = { [weak plugin] address in connection(plugin, address, open: true) }
        let disconnect: @convention(block) (String) -> JSValue = { [weak plugin] address in connection(plugin, address, open: false) }
        let requestAccess: @convention(block) () -> Void = { DispatchQueue.main.async { BluetoothAccess.shared.request() } }
        JSValue.namespace(["setPower": setPower, "connect": connect, "disconnect": disconnect, "requestAccess": requestAccess], in: host, as: "bluetooth")
    }, topic: { BluetoothTopic($0) })
}

private enum BluetoothPower {
    typealias Get = @convention(c) () -> Int32
    typealias Set = @convention(c) (Int32) -> Void
    static let get = privateSymbol(.bluetoothGetPower, as: Get.self)
    static let set = privateSymbol(.bluetoothSetPower, as: Set.self)

    static var missing: [String] { missingSymbols([.bluetoothGetPower, .bluetoothSetPower]) }
}

private func connection(_ plugin: PluginRuntime?, _ address: String, open: Bool) -> JSValue {
    let context = JSContext.current()!
    return JSValue(newPromiseIn: context) { resolve, reject in
        DispatchQueue.main.async {
            let finish: (String?) -> Void = { failure in
                plugin?.queue.async {
                    if let failure {
                        plugin?.callBack(reject!, [JSValue(newErrorFromMessage: failure, in: context)!], Trace("bluetooth"))
                    } else {
                        plugin?.callBack(resolve!, [open ? "connected" : "disconnected"], Trace("bluetooth"))
                    }
                }
            }
            guard CBManager.authorization == .allowedAlways else { return finish("Gary needs Bluetooth permission") }
            guard let device = IOBluetoothDevice(addressString: address), device.isPaired() else { return finish("\(address) is not a paired device") }
            if open {
                Connector.open(device, finish)
            } else {
                let status = device.closeConnection()
                finish(status == kIOReturnSuccess ? nil : "cannot disconnect \(device.name ?? address) (\(status))")
            }
        }
    }
}

private final class Connector: NSObject {
    private static var pending: Set<Connector> = []
    private let done: (String?) -> Void

    private init(_ done: @escaping (String?) -> Void) {
        self.done = done
    }

    static func open(_ device: IOBluetoothDevice, _ done: @escaping (String?) -> Void) {
        if device.isConnected() { return done(nil) }
        let connector = Connector(done)
        let status = device.openConnection(connector, withPageTimeout: 0x2000, authenticationRequired: false)
        guard status == kIOReturnSuccess else { return done("cannot connect \(device.name ?? device.addressString ?? "") (\(status))") }
        pending.insert(connector)
    }

    @objc func connectionComplete(_ device: IOBluetoothDevice, status: IOReturn) {
        Connector.pending.remove(self)
        done(status == kIOReturnSuccess ? nil : "cannot connect \(device.name ?? device.addressString ?? "") (\(status))")
    }
}

private final class BluetoothAccess: NSObject, CBCentralManagerDelegate {
    static let shared = BluetoothAccess()
    private var manager: CBCentralManager?

    func request() {
        if manager == nil { manager = CBCentralManager(delegate: self, queue: .main) }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        BluetoothTopic.current?.restart()
    }
}

private final class BluetoothTopic: NSObject {
    static weak var current: BluetoothTopic?
    private let publish: (JSON, Trace) -> Void
    private var observations: [Observation] = []
    private var notifications: [IOBluetoothUserNotification] = []

    init(_ publish: @escaping (JSON, Trace) -> Void) {
        self.publish = publish
        super.init()
        Self.current = self
        restart()
    }

    deinit {
        for notification in notifications { notification.unregister() }
    }

    func restart() {
        guard CBManager.authorization == .allowedAlways else { return send(Trace("bluetooth-start")) }
        guard notifications.isEmpty else { return send(Trace("bluetooth")) }
        if let notification = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(connected(_:device:))) {
            notifications.append(notification)
        }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.send(Trace("bluetooth-poll")) }
        RunLoop.main.add(timer, forMode: .common)
        observations = [
            Observation { timer.invalidate() },
            Observation(.default, NSNotification.Name("IOBluetoothHostControllerPoweredOnNotification")) { [weak self] in self?.send(Trace("bluetooth-power")) },
            Observation(.default, NSNotification.Name("IOBluetoothHostControllerPoweredOffNotification")) { [weak self] in self?.send(Trace("bluetooth-power")) },
        ]
        send(Trace("bluetooth-start"))
    }

    @objc private func connected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        if let disconnect = device.register(forDisconnectNotification: self, selector: #selector(disconnected(_:device:))) { notifications.append(disconnect) }
        send(Trace("bluetooth-connect"))
    }

    @objc private func disconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        notification.unregister()
        notifications.removeAll { $0 === notification }
        send(Trace("bluetooth-disconnect"))
    }

    func send(_ trace: Trace) {
        let permission: String
        switch CBManager.authorization {
        case .allowedAlways: permission = "allowed"
        case .denied: permission = "denied"
        case .restricted: permission = "restricted"
        default: permission = "notDetermined"
        }
        guard permission == "allowed" else {
            return publish(.object(["available": .bool(false), "permission": .string(permission), "power": .null, "devices": .array([]), "missing": .array([])]), trace)
        }
        let batteries = hidBatteries()
        let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []).compactMap { device -> JSON? in
            guard let address = device.addressString?.lowercased() else { return nil }
            return .object([
                "address": .string(address),
                "name": device.name.map(JSON.string) ?? .null,
                "connected": .bool(device.isConnected()),
                "battery": (battery(device) ?? batteries[address]).map { .number(Double($0)) } ?? .null,
            ])
        }
        let power = IOBluetoothHostController.default()?.powerState
        publish(.object([
            "available": .bool(true), "permission": .string(permission),
            "power": power.map { .bool($0 == kBluetoothHCIPowerStateON) } ?? .null,
            "devices": .array(devices), "missing": .array(BluetoothPower.missing.map(JSON.string)),
        ]), trace)
    }

    private func battery(_ device: IOBluetoothDevice) -> Int? {
        let levels = ["batteryPercentSingle", "batteryPercentCombined", "batteryPercentLeft", "batteryPercentRight"].compactMap { key -> Int? in
            guard device.responds(to: NSSelectorFromString(key)), let value = device.value(forKey: key) as? NSNumber, value.intValue > 0 else { return nil }
            return value.intValue
        }
        return levels.first
    }

    private func hidBatteries() -> [String: Int] {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"), &iterator) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iterator) }
        var levels: [String: Int] = [:]
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let address = IORegistryEntryCreateCFProperty(service, "DeviceAddress" as CFString, nil, 0)?.takeRetainedValue() as? String,
                  let percent = IORegistryEntryCreateCFProperty(service, "BatteryPercent" as CFString, nil, 0)?.takeRetainedValue() as? Int else { continue }
            levels[address.lowercased().replacingOccurrences(of: ":", with: "-")] = percent
        }
        return levels
    }
}
