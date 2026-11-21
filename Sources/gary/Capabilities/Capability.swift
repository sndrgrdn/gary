import CryptoKit
import Foundation
import GaryCore
import JavaScriptCore

enum Permission {
    case accessibility, bluetooth, location, notifications
}

struct Capability {
    let name: String
    var permission: Permission?
    var install: ((JSValue, PluginRuntime) -> Void)?
    var topic: ((@escaping (JSON, Trace) -> Void) -> AnyObject)?

    static let all: [Capability] = [
        .apps,
        .battery,
        .clipboard,
        .clock,
        .exec,
        .files,
        .network,
        .paste,
        .wallpaper,
    ]

    static func names() throws -> CapabilityNames {
        try CapabilityNames(all.map { ($0.name, $0.install != nil, $0.topic != nil) })
    }
}

protocol DemandDrivenTopic: AnyObject {
    func demand(_ demanded: Bool)
}

enum HostResult {
    case now(JSON)
    case later(DispatchQueue, () throws -> JSON)
}

struct HostFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

let home = FileManager.default.homeDirectoryForCurrentUser.path

func missingGrant(_ permission: String, _ api: String) -> String {
    "\(api) needs the \(permission) permission for \(Bundle.main.bundleIdentifier ?? "gary") in System Settings > Privacy & Security"
}

private func message(_ error: Error, _ call: HostCall) -> String {
    error is ArgumentError ? "\(error)" : "\(call.name): \(error)"
}

func savePNG(_ data: Data, in folder: String) throws -> String {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "gary/\(folder)")
    let name = SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
    let url = directory.appending(path: "\(name).png")
    if !FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
    return url.path
}

extension PluginRuntime {
    func installAPI(_ host: JSValue, _ api: String?, _ methods: [String], _ handle: @escaping (HostCall) throws -> HostResult) {
        let context = host.context!
        var target = host
        if let api {
            target = JSValue(newObjectIn: context)
            host.setObject(target, forKeyedSubscript: api as NSString)
        }
        let bridge: @convention(block) (String, String) -> JSValue? = { [weak self] method, text in
            let context = JSContext.current()!
            let call = HostCall(api: api, method: method, arguments: (try? JSON.parse(text))?.array ?? [])
            do {
                switch try handle(call) {
                case .now(let value): return JSValue(object: value.text, in: context)
                case .later(let queue, let work): return self?.promise(in: context, on: queue, call: call, work)
                }
            } catch {
                context.exception = JSValue(newErrorFromMessage: message(error, call), in: context)
                return nil
            }
        }
        context.evaluateScript("""
        (function (target, bridge, methods) {
          methods.forEach(function (method) {
            target[method] = function () {
              var result = bridge(method, JSON.stringify(Array.prototype.slice.call(arguments)));
              return result instanceof Promise ? result.then(JSON.parse) : JSON.parse(result);
            };
          });
        })
        """).call(withArguments: [target, bridge, methods])
    }

    private func promise(in context: JSContext, on worker: DispatchQueue, call: HostCall, _ work: @escaping () throws -> JSON) -> JSValue {
        JSValue(newPromiseIn: context) { [weak self] resolve, reject in
            worker.async {
                let result = Result { try work() }
                self?.queue.async {
                    guard let self else { return }
                    switch result {
                    case .success(let value): self.callBack(resolve!, [value.text], Trace(call.name))
                    case .failure(let error): self.callBack(reject!, [JSValue(newErrorFromMessage: message(error, call), in: context)!], Trace(call.name))
                    }
                }
            }
        }
    }
}
