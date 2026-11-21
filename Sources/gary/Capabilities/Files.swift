import Foundation
import GaryCore
import JavaScriptCore

final class FileWatch {
    let path: String
    let callback: JSValue
    var source: DispatchSourceFileSystemObject?
    var pending: DispatchWorkItem?

    init(path: String, callback: JSValue) {
        self.path = path
        self.callback = callback
    }
}

extension PluginRuntime {
    func installFiles(on host: JSValue) {
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
        let watchFile: @convention(block) (String, JSValue) -> Void = { [weak self] path, callback in
            guard let self, callback.isObject else { return }
            let watch = FileWatch(path: (path as NSString).expandingTildeInPath, callback: callback)
            watches.append(watch)
            arm(watch, attempts: 10)
        }
        host.setObject(watchFile, forKeyedSubscript: "watchFile" as NSString)
    }

    private func arm(_ watch: FileWatch, attempts: Int) {
        let descriptor = open(watch.path, O_EVTONLY)
        guard descriptor >= 0 else {
            if attempts > 0 {
                queue.asyncAfter(deadline: .now() + 0.5) { [weak self, weak watch] in
                    guard let self, let watch, functions != nil else { return }
                    arm(watch, attempts: attempts - 1)
                }
            }
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename, .attrib], queue: queue)
        source.setEventHandler { [weak self, weak watch, weak source] in
            guard let self, let watch, let source else { return }
            if !source.data.isDisjoint(with: [.delete, .rename]) {
                source.cancel()
                arm(watch, attempts: 10)
            }
            watch.pending?.cancel()
            let work = DispatchWorkItem { [weak self, weak watch] in
                guard let self, let watch, functions != nil else { return }
                let text = try? String(contentsOfFile: watch.path, encoding: .utf8)
                callBack(watch.callback, [text ?? NSNull()], Trace("file"))
            }
            watch.pending = work
            queue.asyncAfter(deadline: .now() + 0.02, execute: work)
        }
        source.setCancelHandler { close(descriptor) }
        watch.source = source
        source.resume()
    }
}
