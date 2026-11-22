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
                    try deliver(self, .surface(request, surfaceName(name), origin: origin))
                } catch {
                    let context = JSContext.current()
                    context?.exception = JSValue(newErrorFromMessage: "host.\(request.rawValue): \(error)", in: context)
                }
            } as @convention(block) (JSValue) -> Void
        }
        let callBlock: @convention(block) (String, [String], JSValue, JSValue) -> Void = { [weak self] method, arguments, resolve, reject in
            guard let self else { return }
            deliver(self, .call(method: method, arguments: arguments) { [weak self] response in
                self?.queue.async {
                    switch response {
                    case let .ok(text): self?.callBack(resolve, [text], Trace("host.call"))
                    case let .failure(message): self?.callBack(reject, [message], Trace("host.call"))
                    }
                }
            })
        }
        return context.evaluateScript(PluginScripts.host)?.call(withArguments: [logBlock, read, write, publishBlock] + surfaceBlocks + [callBlock])
    }
}
