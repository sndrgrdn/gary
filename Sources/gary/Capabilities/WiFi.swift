import CoreLocation
import CoreWLAN
import GaryCore

extension Capability {
    static let wifi = Capability(
        name: "wifi",
        summary: "Wi-Fi power, network, signal, and rate. Scan, join a network, and turn Wi-Fi on or off.",
        types: """
        declare namespace Gary {
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
            setPower(on: boolean): null;
            scan(): Promise<WiFiNetwork[]>;
            join(ssid: string, password?: string | null): Promise<"joined">;
            requestLocation(): Promise<string>;
          }
        }
        """,
        example: """
        export default {
          render(state) {
            const wifi = state.wifi;
            if (!wifi?.power) return { type: "icon", symbol: "wifi.slash", style: "dim", action: "on" };
            if (wifi.location !== "authorized") return { type: "text", text: "Allow Location for the network name", action: "location" };
            return { type: "row", children: [{ type: "icon", key: "icon", symbol: "wifi" }, { type: "text", key: "ssid", text: wifi.ssid ?? "Not connected" }] };
          },
          onAction(action) {
            if (action === "on") host.wifi.setPower(true);
            if (action === "location") host.wifi.requestLocation().then((message) => host.log(message));
          },
        } satisfies Gary.BarWidget;
        """,
        permissions: [.location],
        install: { host, plugin in
            plugin.installAPI(host, "wifi", WiFiRequest.methods) { call in
                switch try WiFiRequest.parse(call) {
                case let .setPower(enabled): try .now(setPower(enabled))
                case .scan: .later(.global(qos: .userInitiated)) { try scan() }
                case let .join(ssid, password): .later(.global(qos: .userInitiated)) { try join(ssid, password) }
                case .requestLocation: .later(.main) { .string(Permission.location.request()) }
                }
            }
        },
        topic: CapabilityTopic(type: "WiFi") { WiFiTopic($0) },
    )
}

private func wifiInterface() throws -> CWInterface {
    guard let interface = CWWiFiClient.shared().interface() else { throw HostFailure("this Mac has no Wi-Fi interface") }
    return interface
}

private func setPower(_ enabled: Bool) throws -> JSON {
    do { try wifiInterface().setPower(enabled) } catch {
        throw HostFailure("cannot turn Wi-Fi \(enabled ? "on" : "off"): \(error.localizedDescription)")
    }
    return .null
}

private func scan() throws -> JSON {
    let networks = try wifiInterface().scanForNetworks(withSSID: nil).sorted { $0.rssiValue > $1.rssiValue }
    return .array(networks.map { network in
        .object([
            "ssid": network.ssid.map(JSON.string) ?? .null, "bssid": network.bssid.map(JSON.string) ?? .null,
            "rssi": .number(Double(network.rssiValue)), "noise": .number(Double(network.noiseMeasurement)),
            "channel": network.wlanChannel.map { .number(Double($0.channelNumber)) } ?? .null, "secure": .bool(!network.supportsSecurity(.none)),
        ])
    })
}

private func join(_ ssid: String, _ password: String?) throws -> JSON {
    let interface = try wifiInterface()
    let networks = try interface.scanForNetworks(withSSID: nil)
    guard let network = networks.first(where: { $0.ssid == ssid }) else {
        let hidden = !networks.isEmpty && networks.allSatisfy { $0.ssid == nil }
        throw HostFailure("no network \(ssid) in range" + (hidden ? "; macOS hides network names: " + missingGrant(.location, "wifi") : ""))
    }
    try interface.associate(to: network, password: password)
    return .string("joined")
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
        case .authorizedAlways, .authorizedWhenInUse: "authorized"
        case .denied: "denied"
        case .restricted: "restricted"
        default: "notDetermined"
        }
    }

    func request() {
        manager.requestWhenInUseAuthorization()
    }

    func locationManagerDidChangeAuthorization(_: CLLocationManager) {
        onChange?()
    }
}

private final class WiFiTopic: NSObject, CWEventDelegate, TopicFeed {
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
            publish(.object(["available": .bool(false), "location": .string(LocationAccess.shared.status)]), trace)
            return
        }
        let power = interface.powerOn()
        func optional(_ value: String?) -> JSON {
            value.map(JSON.string) ?? .null
        }
        func number(_ value: Int, when present: Bool) -> JSON {
            present ? .number(Double(value)) : .null
        }
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

    func powerStateDidChangeForWiFiInterface(withName _: String) {
        send(Trace("wifi"))
    }

    func ssidDidChangeForWiFiInterface(withName _: String) {
        send(Trace("wifi"))
    }

    func bssidDidChangeForWiFiInterface(withName _: String) {
        send(Trace("wifi"))
    }

    func linkDidChangeForWiFiInterface(withName _: String) {
        send(Trace("wifi"))
    }

    func linkQualityDidChangeForWiFiInterface(withName _: String, rssi _: Int, transmitRate _: Double) {
        send(Trace("wifi"))
    }

    func modeDidChangeForWiFiInterface(withName _: String) {
        send(Trace("wifi"))
    }
}
