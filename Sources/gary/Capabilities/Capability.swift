import CryptoKit
import Foundation
import GaryCore
import GaryPrivate
import JavaScriptCore

struct Capability {
    let name: String
    let summary: String
    let types: String
    let example: String
    var permissions: [Permission] = []
    var install: ((JSValue, PluginRuntime) -> Void)?
    var topic: CapabilityTopic?

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
        .permissions,
        .session,
        .tray,
        .wallpaper,
        .wifi,
    ]

    static func names() -> CapabilityNames {
        CapabilityNames(all.map { CapabilityDeclaration($0.name, installs: $0.install != nil, publishes: $0.topic != nil) })
    }

    static var topics: [Topic: TopicSource] {
        Dictionary(uniqueKeysWithValues: all.compactMap { capability in capability.topic.map { (Topic.capability(capability.name), $0.source) } })
    }
}

struct CapabilityTopic {
    let type: String
    let source: TopicSource
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

enum HostResult {
    case now(JSON)
    case later(DispatchQueue, () throws -> JSON)
}

struct HostFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) {
        self.description = description
    }
}

let home = FileManager.default.homeDirectoryForCurrentUser.path

func missingGrant(_ permission: Permission, _ api: String) -> String {
    "\(api) needs \(permission.name) for Gary; run gary permissions request \(permission.rawValue)"
}

private func message(_ error: Error, _ call: HostCall) -> String {
    switch error {
    case let error as ArgumentError: error.description
    case let error as HostFailure: "\(call.name): \(error)"
    default: "\(call.name): \(error.localizedDescription)"
    }
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

extension JSContext {
    func newError(_ message: String) -> JSValue {
        JSValue(newErrorFromMessage: message, in: self)
    }
}

extension PluginRuntime {
    func installAPI(_ host: JSValue, _ api: String?, _ methods: [String], _ handle: @escaping (HostCall) throws -> HostResult) {
        let context: JSContext = host.context
        var target = host
        if let api {
            target = JSValue(newObjectIn: context)
            host.setObject(target, forKeyedSubscript: api as NSString)
        }
        let bridge: @convention(block) (String, String) -> JSValue? = { [weak self] method, text in
            guard let context = JSContext.current() else { return nil }
            let call = HostCall(api: api, method: method, arguments: (try? JSON.parse(text))?.array ?? [])
            do {
                switch try handle(call) {
                case let .now(value): return JSValue(object: value.text, in: context)
                case let .later(queue, work): return self?.promise(in: context, on: queue, call: call, work)
                }
            } catch {
                context.exception = context.newError(message(error, call))
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
            guard let resolve, let reject else { return }
            worker.async {
                let result = Result { try work() }
                self?.queue.async {
                    guard let self else { return }
                    switch result {
                    case let .success(value): self.callBack(resolve, [value.text], Trace(call.name))
                    case let .failure(error): self.callBack(reject, [context.newError(message(error, call))], Trace(call.name))
                    }
                }
            }
        }
    }
}
