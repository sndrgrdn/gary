import CoreBluetooth
import GaryCore
import GaryPrivate
import IOBluetooth
import IOKit

extension Capability {
    static let bluetooth = Capability(
        name: "bluetooth",
        summary: "Bluetooth power and paired devices with their battery levels. Turn Bluetooth on or off, and connect or disconnect a device.",
        types: """
        declare namespace Gary {
          type Bluetooth = {
            available: boolean;
            permission: "allowed" | "denied" | "restricted" | "notDetermined";
            power: boolean | null;
            devices: BluetoothDevice[];
            missing: string[];
          }
          type BluetoothDevice = { address: string; name: string | null; connected: boolean; battery: number | null }
          interface Host { bluetooth: BluetoothApi }
          interface BluetoothApi {
            setPower(on: boolean): null;
            connect(address: string): Promise<"connected">;
            disconnect(address: string): Promise<"disconnected">;
            requestAccess(): Promise<string>;
          }
        }
        """,
        example: """
        export default {
          render(state) {
            if (state.bluetooth?.permission === "notDetermined") return { type: "button", action: "allow", children: [{ type: "text", text: "Allow Bluetooth" }] };
            return {
              type: "column",
              children: (state.bluetooth?.devices ?? []).map((device) => ({
                type: "text", key: device.address, action: device.address, style: device.connected ? "bright" : "dim",
                text: `${device.name ?? device.address}${device.battery === null ? "" : ` ${device.battery}%`}`,
              })),
            };
          },
          onAction(action, _payload, state) {
            if (action === "allow") return void host.bluetooth.requestAccess();
            const device = state.bluetooth?.devices.find((each) => each.address === action);
            if (device) (device.connected ? host.bluetooth.disconnect(action) : host.bluetooth.connect(action)).catch((error) => host.log(String(error)));
          },
        } satisfies Gary.Panel;
        """,
        permissions: [.bluetooth],
        install: { host, plugin in
            plugin.installAPI(host, "bluetooth", BluetoothRequest.methods) { call in
                switch try BluetoothRequest.parse(call) {
                case let .setPower(enabled):
                    guard CBManager.authorization == .allowedAlways else { throw HostFailure(missingGrant(.bluetooth, "bluetooth")) }
                    guard let set = BluetoothPower.set
                    else { throw HostFailure("IOBluetoothPreferenceSetControllerPowerState is missing on this macOS") }
                    set(enabled ? 1 : 0)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { BluetoothTopic.current?.send(Trace("bluetooth-power")) }
                    return .now(.null)
                case let .connect(address):
                    return .later(.global(qos: .userInitiated)) { try connection(address, open: true) }
                case let .disconnect(address):
                    return .later(.global(qos: .userInitiated)) { try connection(address, open: false) }
                case .requestAccess:
                    return .later(.main) { .string(Permission.bluetooth.request()) }
                }
            }
        },
        topic: CapabilityTopic(type: "Bluetooth") { BluetoothTopic($0) },
    )
}

private enum BluetoothPower {
    typealias Set = @convention(c) (Int32) -> Void
    static let set = privateSymbol(.bluetoothSetPower, as: Set.self)

    static var missing: [String] {
        missingSymbols([.bluetoothSetPower])
    }
}

private func connection(_ address: String, open: Bool) throws -> JSON {
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var failure: String?
    DispatchQueue.main.async {
        let finish: (String?) -> Void = { reason in
            failure = reason
            done.signal()
        }
        guard CBManager.authorization == .allowedAlways else { return finish(missingGrant(.bluetooth, "bluetooth")) }
        guard let device = IOBluetoothDevice(addressString: address), device.isPaired() else { return finish("\(address) is not a paired device") }
        if open {
            Connector.open(device, finish)
        } else {
            let status = device.closeConnection()
            finish(status == kIOReturnSuccess ? nil : "cannot disconnect \(device.name ?? address) (\(status))")
        }
    }
    guard done.wait(timeout: .now() + 20) == .success
    else { throw HostFailure("\(open ? "connecting" : "disconnecting") \(address) took longer than 20 s") }
    if let failure {
        throw HostFailure(failure)
    }
    return .string(open ? "connected" : "disconnected")
}

private final class Connector: NSObject {
    private static var pending: Set<Connector> = []
    private let done: (String?) -> Void

    private init(_ done: @escaping (String?) -> Void) {
        self.done = done
    }

    static func open(_ device: IOBluetoothDevice, _ done: @escaping (String?) -> Void) {
        if device.isConnected() {
            done(nil)
            return
        }
        let connector = Connector(done)
        let status = device.openConnection(connector, withPageTimeout: 0x2000, authenticationRequired: false)
        guard status == kIOReturnSuccess else { done("cannot connect \(device.name ?? device.addressString ?? "") (\(status))")
            return
        }
        pending.insert(connector)
    }

    @objc func connectionComplete(_ device: IOBluetoothDevice, status: IOReturn) {
        Connector.pending.remove(self)
        done(status == kIOReturnSuccess ? nil : "cannot connect \(device.name ?? device.addressString ?? "") (\(status))")
    }
}

final class BluetoothAccess: NSObject, CBCentralManagerDelegate {
    static let shared = BluetoothAccess()
    private var manager: CBCentralManager?

    func request() {
        if manager == nil {
            manager = CBCentralManager(delegate: self, queue: .main)
        }
    }

    func centralManagerDidUpdateState(_: CBCentralManager) {
        BluetoothTopic.current?.restart()
    }
}

@objc private protocol BluetoothBatteryPercents {
    @objc optional var batteryPercentSingle: UInt8 { get }
    @objc optional var batteryPercentCombined: UInt8 { get }
    @objc optional var batteryPercentLeft: UInt8 { get }
    @objc optional var batteryPercentRight: UInt8 { get }
}

extension IOBluetoothDevice: BluetoothBatteryPercents {}

private final class BluetoothTopic: NSObject, TopicFeed {
    weak static var current: BluetoothTopic?
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
        for notification in notifications {
            notification.unregister()
        }
    }

    func restart() {
        guard CBManager.authorization == .allowedAlways else { send(Trace("bluetooth-start"))
            return
        }
        guard notifications.isEmpty else { send(Trace("bluetooth"))
            return
        }
        if let notification = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(connected(_:device:))) {
            notifications.append(notification)
        }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.send(Trace("bluetooth-poll")) }
        RunLoop.main.add(timer, forMode: .common)
        observations = [
            Observation { timer.invalidate() },
            Observation(.default, NSNotification.Name("IOBluetoothHostControllerPoweredOnNotification")) { [weak self] in
                self?.send(Trace("bluetooth-power"))
            },
            Observation(.default, NSNotification.Name("IOBluetoothHostControllerPoweredOffNotification")) { [weak self] in
                self?.send(Trace("bluetooth-power"))
            },
        ]
        send(Trace("bluetooth-start"))
    }

    @objc private func connected(_: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        if let disconnect = device
            .register(forDisconnectNotification: self, selector: #selector(disconnected(_:device:)))
        {
            notifications.append(disconnect)
        }
        send(Trace("bluetooth-connect"))
    }

    @objc private func disconnected(_ notification: IOBluetoothUserNotification, device _: IOBluetoothDevice) {
        notification.unregister()
        notifications.removeAll { $0 === notification }
        send(Trace("bluetooth-disconnect"))
    }

    func send(_ trace: Trace) {
        let permission = switch CBManager.authorization {
        case .allowedAlways: "allowed"
        case .denied: "denied"
        case .restricted: "restricted"
        default: "notDetermined"
        }
        guard permission == "allowed" else {
            publish(
                .object(["available": .bool(false), "permission": .string(permission), "power": .null, "devices": .array([]), "missing": .array([])]),
                trace,
            )
            return
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
        let percents: BluetoothBatteryPercents = device
        let levels = [percents.batteryPercentSingle, percents.batteryPercentCombined, percents.batteryPercentLeft, percents.batteryPercentRight]
        return levels.compactMap(\.self).first { $0 > 0 }.map(Int.init)
    }

    private func hidBatteries() -> [String: Int] {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"), &iterator) == KERN_SUCCESS
        else { return [:] }
        defer { IOObjectRelease(iterator) }
        var levels: [String: Int] = [:]
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let address = IORegistryEntryCreateCFProperty(service, "DeviceAddress" as CFString, nil, 0)?.takeRetainedValue() as? String,
                  let percent = IORegistryEntryCreateCFProperty(service, "BatteryPercent" as CFString, nil, 0)?.takeRetainedValue() as? Int
            else { continue }
            levels[address.lowercased().replacingOccurrences(of: ":", with: "-")] = percent
        }
        return levels
    }
}
