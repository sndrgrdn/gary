import Foundation
import GaryCore
@preconcurrency import JavaScriptCore

extension PluginRuntime {
    func makeHost(in context: JSContext) -> JSValue? {
        let id = id
        let logBlock: @convention(block) (String) -> Void = { message in log("plugin \(id): \(message)") }
        let storageURL = Paths.storage.appending(path: "\(id).json")
        let read: @convention(block) () -> String? = { try? String(contentsOf: storageURL, encoding: .utf8) }
        let write: @convention(block) (String) -> Void = { text in
            do {
                try FileManager.default.createDirectory(at: Paths.storage, withIntermediateDirectories: true)
                try Data(text.utf8).write(to: storageURL, options: .atomic)
            } catch {
                log("plugin \(id): storage not saved: \(error)")
            }
        }
        let publishBlock: @convention(block) (JSValue) -> Void = { [weak self] value in
            guard let self, let text = value.context.objectForKeyedSubscript("JSON").invokeMethod("stringify", withArguments: [value]).toString(),
                  let json = try? JSON.parse(text) else { return }
            hub.publish(.plugin(id), json, Trace("publish"))
        }
        let surfaceBlocks = [SurfaceRequest.show, .hide, .toggle].map { request in
            { [weak self] name in
                self?.assumeIsolated { runtime in
                    do {
                        try runtime.deliver(runtime, .surface(request, runtime.surfaceAddress(name), origin: runtime.origin))
                    } catch {
                        let context = JSContext.current()
                        context?.exception = JSValue(newErrorFromMessage: "host.\(request.rawValue): \(error)", in: context)
                    }
                }
            } as @convention(block) (JSValue) -> Void
        }
        let callBlock: @convention(block) (String, String, String, [String], JSValue, JSValue)
            -> Void = { [weak self] plugin, kind, method, args, resolve, reject in
                self?.assumeIsolated { runtime in
                    guard let target = CallTarget(plugin: plugin, kind: kind) else {
                        runtime.callBack(reject, ["\(plugin) is not a plugin id"], Trace("host.call"))
                        return
                    }
                    runtime.callPlugin(target, method, args, resolve, reject)
                }
            }
        let kinds = bundle.manifest.kinds.map(\.rawValue)
        return context.evaluateScript(PluginScripts.host)?
            .call(withArguments: [logBlock, read, write, publishBlock] + surfaceBlocks + [callBlock, "\(id)", kinds])
    }

    private func callPlugin(_ target: CallTarget, _ method: String, _ args: [String], _ resolve: JSValue, _ reject: JSValue) {
        deliver(self, .call(target, method: method, arguments: args) { [weak self] response in
            self?.onQueue { runtime in
                switch response {
                case let .ok(text): runtime.callBack(resolve, [text], Trace("host.call"))
                case let .failure(message): runtime.callBack(reject, [message], Trace("host.call"))
                }
            }
        })
    }

    func surfaceAddress(_ value: JSValue) throws -> SurfaceAddress {
        if value.isUndefined {
            return SurfaceAddress(id)
        }
        guard value.isString, let text = value.toString(), let address = SurfaceAddress(text) ?? SurfaceAddress(id, surface: text) else {
            throw RenderError("\(value.toString() ?? "this") is not a surface name or address; " +
                "use lowercase letters, digits and hyphens, such as osd, you.music, or you.music:osd")
        }
        guard address.plugin != id || bundle.manifest.surfaceKind(address.surface) != nil else {
            let names = bundle.manifest.surfaceNames
            throw RenderError("no surface \(address.surface); " +
                (names.isEmpty ? "this plugin has no panel, overlay, or menu" : "this plugin declares \(names.joined(separator: ", "))"))
        }
        return address
    }
}
