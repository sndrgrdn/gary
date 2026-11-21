import CoreLocation
import CoreWLAN
import GaryCore
import JavaScriptCore

extension Capability {
    static let wifi = Capability(name: "wifi", summary: "Wi-Fi power, network, signal, and rate. Scan, join a network, and turn Wi-Fi on or off.", types: """
    declare namespace Gary {
      interface State { wifi?: WiFi }
      interface WiFi {
        available: boolean;
        location: "authorized" | "denied" | "restricted" | "notDetermined";
        interface?: string | null;
        power?: boolean;
        connected?: boolean;
        ssid?: string | null;
        bssid?: string | null;
        rssi?: number | null;
        noise?: number | null;
        channel?: number | null;
        transmitRate?: number | null;
      }
      interface WiFiNetwork { ssid: string | null; bssid: string | null; rssi: number; noise: number; channel: number | null; secure: boolean }
      interface Host { wifi: WiFiApi }
      interface WiFiApi {
        setPower(on: boolean): void;
        scan(): Promise<WiFiNetwork[]>;
        join(ssid: string, password?: string | null): Promise<"joined">;
        requestLocation(): void;
      }
    }
    """, permissions: [.location], install: { host, plugin in
        let setPower: @convention(block) (Bool) -> Void = { on in
            guard let interface = CWWiFiClient.shared().interface() else { return JSValue.fail("this Mac has no Wi-Fi interface") }
            do { try interface.setPower(on) } catch { JSValue.fail("cannot turn Wi-Fi \(on ? "on" : "off"): \(error.localizedDescription)") }
        }
        let scan: @convention(block) () -> JSValue = { [weak plugin] in
            promise(plugin, "wifi-scan") { interface in
                let networks = try interface.scanForNetworks(withSSID: nil).sorted { $0.rssiValue > $1.rssiValue }
                return networks.map { network -> [String: Any] in
                    ["ssid": network.ssid ?? NSNull(), "bssid": network.bssid ?? NSNull(), "rssi": network.rssiValue, "noise": network.noiseMeasurement,
                     "channel": network.wlanChannel?.channelNumber ?? NSNull(), "secure": !network.supportsSecurity(.none)]
                }
            }
        }
        let join: @convention(block) (String, JSValue) -> JSValue = { [weak plugin] ssid, password in
            promise(plugin, "wifi-join") { interface in
                let networks = try interface.scanForNetworks(withSSID: nil)
                guard let network = networks.first(where: { $0.ssid == ssid }) else {
                    let hidden = !networks.isEmpty && networks.allSatisfy { $0.ssid == nil }
                    throw WiFiError("no network \(ssid) in range" + (hidden ? "; macOS hides network names: " + missingGrant(.location, "wifi") : ""))
                }
                try interface.associate(to: network, password: password.optionalString)
                return "joined"
            }
        }
        let requestLocation: @convention(block) () -> Void = { DispatchQueue.main.async { LocationAccess.shared.request() } }
        JSValue.namespace(["setPower": setPower, "scan": scan, "join": join, "requestLocation": requestLocation], in: host, as: "wifi")
    }, topic: { WiFiTopic($0) })
}

private struct WiFiError: Error, LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

private func promise(_ plugin: PluginRuntime?, _ cause: String, _ work: @escaping (CWInterface) throws -> Any) -> JSValue {
    let context = JSContext.current()!
    return JSValue(newPromiseIn: context) { resolve, reject in
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () throws -> Any in
                guard let interface = CWWiFiClient.shared().interface() else { throw WiFiError("this Mac has no Wi-Fi interface") }
                return try work(interface)
            }
            plugin?.queue.async {
                switch result {
                case .success(let value): plugin?.callBack(resolve!, [value], Trace(cause))
                case .failure(let error): plugin?.callBack(reject!, [JSValue(newErrorFromMessage: error.localizedDescription, in: context)!], Trace(cause))
                }
            }
        }
    }
}

final class LocationAccess: NSObject, CLLocationManagerDelegate {
    static let shared = LocationAccess()
    private let manager = CLLocationManager()
    var onChange: (() -> Void)?

    override init() {
        super.init()
        manager.delegate = self
    }

    var status: String {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        default: return "notDetermined"
        }
    }

    func request() {
        manager.requestWhenInUseAuthorization()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onChange?()
    }
}

private final class WiFiTopic: NSObject, CWEventDelegate {
    private let publish: (JSON, Trace) -> Void
    private let client = CWWiFiClient.shared()

    init(_ publish: @escaping (JSON, Trace) -> Void) {
        self.publish = publish
        super.init()
        LocationAccess.shared.onChange = { [weak self] in self?.send(Trace("location")) }
        client.delegate = self
        for event in [CWEventType.powerDidChange, .ssidDidChange, .bssidDidChange, .linkDidChange, .linkQualityDidChange, .modeDidChange] {
            do { try client.startMonitoringEvent(with: event) } catch { log("wifi: cannot monitor \(event.rawValue): \(error)") }
        }
        send(Trace("wifi-start"))
    }

    deinit {
        try? client.stopMonitoringAllEvents()
        client.delegate = nil
        LocationAccess.shared.onChange = nil
    }

    private func send(_ trace: Trace) {
        guard let interface = client.interface() else {
            return publish(.object(["available": .bool(false), "location": .string(LocationAccess.shared.status)]), trace)
        }
        let power = interface.powerOn()
        func optional(_ value: String?) -> JSON { value.map(JSON.string) ?? .null }
        func number(_ value: Int, when present: Bool) -> JSON { present ? .number(Double(value)) : .null }
        let linked = power && interface.wlanChannel() != nil
        publish(.object([
            "available": .bool(true),
            "interface": optional(interface.interfaceName),
            "power": .bool(power),
            "connected": .bool(linked),
            "ssid": optional(interface.ssid()),
            "bssid": optional(interface.bssid()),
            "rssi": number(interface.rssiValue(), when: linked),
            "noise": number(interface.noiseMeasurement(), when: linked),
            "channel": interface.wlanChannel().map { .number(Double($0.channelNumber)) } ?? .null,
            "transmitRate": linked ? .number(interface.transmitRate()) : .null,
            "location": .string(LocationAccess.shared.status),
        ]), trace)
    }

    func powerStateDidChangeForWiFiInterface(withName interfaceName: String) { send(Trace("wifi")) }
    func ssidDidChangeForWiFiInterface(withName interfaceName: String) { send(Trace("wifi")) }
    func bssidDidChangeForWiFiInterface(withName interfaceName: String) { send(Trace("wifi")) }
    func linkDidChangeForWiFiInterface(withName interfaceName: String) { send(Trace("wifi")) }
    func linkQualityDidChangeForWiFiInterface(withName interfaceName: String, rssi: Int, transmitRate: Double) { send(Trace("wifi")) }
    func modeDidChangeForWiFiInterface(withName interfaceName: String) { send(Trace("wifi")) }
}
