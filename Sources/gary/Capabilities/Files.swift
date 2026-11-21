import Foundation
import GaryCore
import JavaScriptCore

extension Capability {
    static let files = Capability(name: "files", types: """
    declare namespace Gary {
      interface Host {
        readFile(path: string): string;
        watchFile(path: string, callback: (text: string | null) => void): void;
      }
    }
    """, install: { host, plugin in
        let readFile: @convention(block) (String) -> String? = { path in
            let expanded = (path as NSString).expandingTildeInPath
            guard let text = try? String(contentsOfFile: expanded, encoding: .utf8) else {
                let context = JSContext.current()!
                context.exception = JSValue(newErrorFromMessage: "cannot read \(path)", in: context)
                return nil
            }
            return text
        }
        host.setObject(readFile, forKeyedSubscript: "readFile" as NSString)
        let watchFile: @convention(block) (String, JSValue) -> Void = { [weak plugin] path, callback in
            guard let plugin, callback.isObject else { return }
            let watch = FileWatch(path: (path as NSString).expandingTildeInPath, callback: callback)
            plugin.onStop {
                watch.source?.cancel()
                watch.pending?.cancel()
            }
            watch.arm(in: plugin, attempts: 10)
        }
        host.setObject(watchFile, forKeyedSubscript: "watchFile" as NSString)
    })
}

private final class FileWatch {
    let path: String
    let callback: JSValue
    var source: DispatchSourceFileSystemObject?
    var pending: DispatchWorkItem?

    init(path: String, callback: JSValue) {
        self.path = path
        self.callback = callback
    }

    func arm(in plugin: PluginRuntime, attempts: Int) {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else {
            if attempts > 0 {
                plugin.queue.asyncAfter(deadline: .now() + 0.5) { [weak self, weak plugin] in
                    guard let self, let plugin, plugin.isRunning else { return }
                    arm(in: plugin, attempts: attempts - 1)
                }
            }
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename, .attrib], queue: plugin.queue)
        source.setEventHandler { [weak self, weak plugin, weak source] in
            guard let self, let plugin, let source else { return }
            if !source.data.isDisjoint(with: [.delete, .rename]) {
                source.cancel()
                arm(in: plugin, attempts: 10)
            }
            pending?.cancel()
            let work = DispatchWorkItem { [weak self, weak plugin] in
                guard let self, let plugin else { return }
                let text = try? String(contentsOfFile: path, encoding: .utf8)
                plugin.callBack(callback, [text ?? NSNull()], Trace("file"))
            }
            pending = work
            plugin.queue.asyncAfter(deadline: .now() + 0.02, execute: work)
        }
        source.setCancelHandler { close(descriptor) }
        self.source = source
        source.resume()
    }
}
