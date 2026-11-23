import CryptoKit
import Foundation
import GaryCore
import GaryPrivate
@preconcurrency import JavaScriptCore

nonisolated struct Capability {
    let name: String
    let summary: String
    let types: String
    let example: String
    var permissions: [Permission] = []
    var manifestEntry: String?
    var install: (@Sendable (JSValue, PluginRuntime) -> Void)?
    var topic: CapabilityTopic?

    static let all: [Capability] = [
        .apps,
        .audio,
        .battery,
        .bluetooth,
        .brightness,
        .calendar,
        .clipboard,
        .clock,
        .colorpicker,
        .dock,
        .exec,
        .files,
        .focus,
        .hotkeys,
        .hyperkey,
        .mediakeys,
        .menubar,
        .network,
        .notifications,
        .notify,
        .nowplaying,
        .paste,
        .permissions,
        .power,
        .screen,
        .session,
        .system,
        .toast,
        .tray,
        .vision,
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

nonisolated struct CapabilityTopic {
    let type: String
    let source: TopicSource
}

nonisolated func privateSymbol<T>(_ symbol: GarySymbol, as type: T.Type) -> T? {
    gary_private_resolve(symbol.rawValue).map { unsafeBitCast($0, to: type) }
}

nonisolated extension String {
    init(cChars: [CChar]) {
        self.init(decoding: cChars.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

nonisolated func runLoopThread(_ name: String) -> CFRunLoop {
    let ready = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var loop: CFRunLoop?
    let thread = Thread {
        loop = CFRunLoopGetCurrent()
        RunLoop.current.add(NSMachPort(), forMode: .default)
        ready.signal()
        RunLoop.current.run()
    }
    thread.name = name
    thread.qualityOfService = .userInteractive
    thread.start()
    ready.wait()
    return loop ?? CFRunLoopGetMain()
}

nonisolated func missingSymbols(_ symbols: [GarySymbol]) -> [String] {
    symbols.filter { gary_private_resolve($0.rawValue) == nil }.map { String(cString: gary_private_symbol($0.rawValue).symbol) }
}

final class Observation {
    private let cancel: () -> Void

    init(_ cancel: @escaping () -> Void) {
        self.cancel = cancel
    }

    convenience init(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping @MainActor @Sendable () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in MainActor.assumeIsolated(handler) }
        self.init { center.removeObserver(token) }
    }

    isolated deinit { cancel() }
}

final nonisolated class Holds {
    private var ids: Set<Int> = []
    private let release: (Int) -> Void

    init(release: @escaping (Int) -> Void) {
        self.release = release
    }

    func add(_ id: Int) -> Int {
        ids.insert(id)
        return id
    }

    func stop(_ id: Int) {
        if ids.remove(id) != nil {
            release(id)
        }
    }

    func stopAll() {
        ids.forEach(release)
        ids = []
    }
}

nonisolated enum HostResult {
    case now(JSON)
    case later(DispatchQueue, @Sendable () throws -> JSON)
    case main(@MainActor @Sendable () throws -> JSON)
    case pending((@escaping @Sendable (Result<JSON, Error>) -> Void) -> Void)
}

nonisolated struct HostFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) {
        self.description = description
    }
}

nonisolated let home = FileManager.default.homeDirectoryForCurrentUser.path

nonisolated func missingGrant(_ permission: Permission, _ api: String) -> String {
    "\(api) needs \(permission.name) for Gary; run gary permissions request \(permission.rawValue)"
}

private nonisolated func message(_ error: Error, _ call: HostCall) -> String {
    switch error {
    case let error as ArgumentError: error.description
    case let error as HostFailure: "\(call.name): \(error)"
    default: "\(call.name): \(error.localizedDescription)"
    }
}

nonisolated func pngFolder(_ folder: String) -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "gary/\(folder)")
}

nonisolated func savePNG(_ data: Data, in folder: String) throws -> String {
    let directory = pngFolder(folder)
    let name = SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
    let url = directory.appending(path: "\(name).png")
    if !FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
    return url.path
}

nonisolated extension JSContext {
    func newError(_ message: String) -> JSValue {
        JSValue(newErrorFromMessage: message, in: self)
    }
}

nonisolated extension PluginRuntime {
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
                case let .later(queue, work):
                    return self?.promise(in: context, call: call) { finish in queue.async { finish(Result { try work() }) } }
                case let .main(work):
                    return self?.promise(in: context, call: call) { finish in DispatchQueue.main.async { finish(Result { try work() }) } }
                case let .pending(start): return self?.promise(in: context, call: call, start)
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

    private func promise(
        in context: JSContext,
        call: HostCall,
        _ start: @escaping (@escaping @Sendable (Result<JSON, Error>) -> Void) -> Void,
    ) -> JSValue {
        JSValue(newPromiseIn: context) { [weak self] resolve, reject in
            guard let self, let resolve, let reject else { return }
            start { [weak self] result in
                guard let self else { return }
                queue.async {
                    switch result {
                    case let .success(value): self.callBack(resolve, [value.text], Trace(call.name))
                    case let .failure(error): self.callBack(reject, [context.newError(message(error, call))], Trace(call.name))
                    }
                }
            }
        }
    }
}
