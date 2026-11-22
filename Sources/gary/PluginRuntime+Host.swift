import Foundation
import GaryCore
import JavaScriptCore

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
                guard let self else { return }
                do {
                    try deliver(self, .surface(request, surfaceAddress(name), origin: origin))
                } catch {
                    let context = JSContext.current()
                    context?.exception = JSValue(newErrorFromMessage: "host.\(request.rawValue): \(error)", in: context)
                }
            } as @convention(block) (JSValue) -> Void
        }
        let callBlock: @convention(block) (String, String, [String], JSValue, JSValue) -> Void = { [weak self] kind, method, args, resolve, reject in
            guard let self else { return }
            deliver(self, .call(kind: PluginKind(rawValue: kind), method: method, arguments: args) { [weak self] response in
                self?.queue.async {
                    switch response {
                    case let .ok(text): self?.callBack(resolve, [text], Trace("host.call"))
                    case let .failure(message): self?.callBack(reject, [message], Trace("host.call"))
                    }
                }
            })
        }
        let kinds = bundle.manifest.kinds.map(\.rawValue)
        return context.evaluateScript(PluginScripts.host)?
            .call(withArguments: [logBlock, read, write, publishBlock] + surfaceBlocks + [callBlock, "\(id)", kinds])
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
