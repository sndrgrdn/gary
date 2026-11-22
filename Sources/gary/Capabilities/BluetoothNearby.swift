import CoreBluetooth
import GaryCore
import IOBluetooth

final class BluetoothDiscovery: NSObject, IOBluetoothDeviceInquiryDelegate {
    static let shared = BluetoothDiscovery()
    private var holders: Set<ObjectIdentifier> = []
    private var found: [String: IOBluetoothDevice] = [:]
    private lazy var inquiry: IOBluetoothDeviceInquiry? = {
        let inquiry = IOBluetoothDeviceInquiry(delegate: self)
        inquiry?.updateNewDeviceNames = true
        return inquiry
    }()

    var nearby: [JSON] {
        found.values.filter { !$0.isPaired() }.compactMap { device in
            device.addressString.map { .object(["address": .string($0.lowercased()), "name": device.name.map(JSON.string) ?? .null]) }
        }
    }

    func hold(_ owner: ObjectIdentifier, _ wanted: Bool) {
        let before = holders.isEmpty
        if wanted {
            holders.insert(owner)
        } else {
            holders.remove(owner)
        }
        guard before != holders.isEmpty else { return }
        if holders.isEmpty {
            log("bluetooth: discovery stopped")
            inquiry?.stop()
            found = [:]
            BluetoothTopic.current?.send(Trace("bluetooth-nearby"))
        } else {
            log("bluetooth: discovery started")
            resume()
        }
    }

    func resume() {
        guard !holders.isEmpty, CBManager.authorization == .allowedAlways,
              IOBluetoothHostController.default()?.powerState == kBluetoothHCIPowerStateON
        else { return }
        inquiry?.start()
    }

    func deviceInquiryDeviceFound(_: IOBluetoothDeviceInquiry, device: IOBluetoothDevice) {
        guard let address = device.addressString else { return }
        found[address] = device
        BluetoothTopic.current?.send(Trace("bluetooth-nearby"))
    }

    func deviceInquiryDeviceNameUpdated(_: IOBluetoothDeviceInquiry, device _: IOBluetoothDevice, devicesRemaining _: UInt32) {
        BluetoothTopic.current?.send(Trace("bluetooth-nearby"))
    }

    func deviceInquiryComplete(_: IOBluetoothDeviceInquiry, error: IOReturn, aborted: Bool) {
        if error == kIOReturnSuccess, !aborted {
            resume()
        }
    }
}

final class BluetoothPairer: NSObject {
    private static var pending: Set<BluetoothPairer> = []
    private let pair: IOBluetoothDevicePair
    private let name: String
    private let finish: (Result<JSON, Error>) -> Void

    private init(_ device: IOBluetoothDevice, _ finish: @escaping (Result<JSON, Error>) -> Void) {
        pair = IOBluetoothDevicePair(device: device)
        name = device.name ?? device.addressString ?? ""
        self.finish = finish
    }

    static func start(_ address: String, _ finish: @escaping (Result<JSON, Error>) -> Void) throws {
        guard CBManager.authorization == .allowedAlways else { throw HostFailure(missingGrant(.bluetooth, "bluetooth")) }
        guard let device = IOBluetoothDevice(addressString: address) else { throw HostFailure("\(address) is not a Bluetooth address") }
        let pairer = BluetoothPairer(device, finish)
        pairer.pair.delegate = pairer
        let status = pairer.pair.start()
        guard status == kIOReturnSuccess else { throw HostFailure("cannot pair \(pairer.name) (\(status))") }
        pending.insert(pairer)
    }

    private func done(_ failure: String?) {
        guard BluetoothPairer.pending.remove(self) != nil else { return }
        finish(failure.map { .failure(HostFailure($0)) } ?? .success(.string("paired")))
        BluetoothTopic.current?.send(Trace("bluetooth-pair"))
    }

    private func refuse(_ asks: String) {
        pair.stop()
        done("\(name) asks for \(asks), which Gary cannot show; pair it in System Settings > Bluetooth")
    }

    @objc func devicePairingFinished(_: IOBluetoothDevicePair, error: IOReturn) {
        done(error == kIOReturnSuccess ? nil : "cannot pair \(name) (\(error))")
    }

    @objc func devicePairingPINCodeRequest(_: IOBluetoothDevicePair) {
        refuse("a PIN")
    }

    @objc func devicePairingUserConfirmationRequest(_: IOBluetoothDevicePair, numericValue _: BluetoothNumericValue) {
        pair.replyUserConfirmation(false)
        refuse("a code to confirm")
    }

    @objc func devicePairingUserPasskeyNotification(_: IOBluetoothDevicePair, passkey _: BluetoothPasskey) {
        refuse("a passkey to type")
    }
}
