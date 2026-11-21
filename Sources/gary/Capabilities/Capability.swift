import CryptoKit
import Foundation
import GaryCore
import GaryPrivate
import JavaScriptCore

struct Capability {
    let name: String
    let summary: String
    let types: String
    var permissions: [Permission] = []
    var install: ((JSValue, PluginRuntime) -> Void)?
    var topic: TopicSource?

    static let all: [Capability] = [
        .apps,
        .audio,
        .battery,
        .bluetooth,
        .brightness,
        .clipboard,
        .clock,
        .dock,
        .exec,
        .files,
        .focus,
        .mediakeys,
        .menubar,
        .network,
        .notifications,
        .nowplaying,
        .paste,
        .tray,
        .wallpaper,
        .wifi,
    ]

    static func names() throws -> CapabilityNames {
        try CapabilityNames(all.map { ($0.name, $0.install != nil, $0.topic != nil) })
    }

    static var topics: [Topic: TopicSource] {
        Dictionary(uniqueKeysWithValues: all.compactMap { capability in capability.topic.map { (Topic.capability(capability.name), $0) } })
    }
}

func privateSymbol<T>(_ symbol: GarySymbol, as type: T.Type) -> T? {
    gary_private_resolve(symbol.rawValue).map { unsafeBitCast($0, to: type) }
}

func missingSymbols(_ symbols: [GarySymbol]) -> [String] {
    symbols.filter { gary_private_resolve($0.rawValue) == nil }.map { String(cString: gary_private_symbol($0.rawValue).symbol) }
}

final class Observation {
    private let cancel: () -> Void

    init(_ cancel: @escaping () -> Void) {
        self.cancel = cancel
    }

    convenience init(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in handler() }
        self.init { center.removeObserver(token) }
    }

    deinit { cancel() }
}

extension JSValue {
    static func fail(_ message: String) {
        let context = JSContext.current()!
        context.exception = JSValue(newErrorFromMessage: message, in: context)
    }

    static func namespace(_ functions: [String: Any], in host: JSValue, as name: String) {
        let object = JSValue(newObjectIn: host.context)!
        for (key, function) in functions { object.setObject(function, forKeyedSubscript: key as NSString) }
        host.setObject(object, forKeyedSubscript: name as NSString)
    }

    var optionalString: String? { isUndefined || isNull ? nil : toString() }
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

func missingGrant(_ permission: Permission, _ api: String) -> String {
    "\(api) needs \(permission.name) for Gary; run gary permissions request \(permission.rawValue)"
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
