import Foundation
import GaryCore
import JavaScriptCore

extension Capability {
    static let files = Capability(name: "files", summary: "Read, write, list, remove, and watch files.", types: """
    declare namespace Gary {
      interface Host {
        readFile(path: string): string;
        writeFile(path: string, text: string): null;
        mkdir(path: string): null;
        remove(path: string): boolean;
        list(path: string): FileEntry[];
        watchFile(path: string, callback: (text: string | null) => void): void;
      }
      interface FileEntry { name: string; type: "file" | "directory" | "link" | "other"; size: number }
    }
    """, example: """
    const path = "~/Documents/scratch.txt";
    let text = "";
    host.watchFile(path, (contents) => {
      text = contents ?? "";
    });

    module.exports = {
      render() {
        return { type: "input", value: text, placeholder: "Scratch", submit: "save" };
      },
      onAction(action, payload) {
        if (action === "save" && typeof payload === "string") host.writeFile(path, payload);
      },
    } satisfies Gary.Menu;
    """, install: { host, plugin in
        plugin.installAPI(host, nil, FilesRequest.methods) { call in try .now(perform(FilesRequest.parse(call, home: home))) }
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

private func perform(_ request: FilesRequest) throws -> JSON {
    let files = FileManager.default
    do {
        switch request {
        case let .read(path):
            return try .string(String(contentsOfFile: path, encoding: .utf8))
        case let .write(path, text):
            try Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        case let .makeDirectory(path):
            try files.createDirectory(atPath: path, withIntermediateDirectories: true)
        case let .remove(path):
            guard (try? files.attributesOfItem(atPath: path)) != nil else { return .bool(false) }
            try files.removeItem(atPath: path)
            return .bool(true)
        case let .list(path):
            return try .array(files.contentsOfDirectory(atPath: path).sorted().map { name in
                let attributes = try? files.attributesOfItem(atPath: path + "/" + name)
                let type = attributes?[.type] as? FileAttributeType
                return .object([
                    "name": .string(name),
                    "type": .string(type == .typeDirectory ? "directory" : type == .typeSymbolicLink ? "link" : type == .typeRegular ? "file" :
                        "other"),
                    "size": .number(Double(attributes?[.size] as? Int ?? 0)),
                ])
            })
        }
    } catch {
        throw HostFailure(error.localizedDescription)
    }
    return .null
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
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename, .attrib],
            queue: plugin.queue,
        )
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
