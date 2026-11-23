import Foundation
import GaryCore
@preconcurrency import JavaScriptCore

nonisolated extension Capability {
    static let files = Capability(
        name: "files",
        summary: "Read, write, list, remove, and watch files. A path that does not start with `/` or `~` is relative to the plugin folder.",
        types: """
        declare namespace Gary {
          interface Host {
            readFile(path: string): string;
            writeFile(path: string, text: string): null;
            mkdir(path: string): null;
            remove(path: string): boolean;
            list(path: string): FileEntry[];
            watchFile(path: string, callback: (text: string | null) => void): void;
          }
          type FileEntry = { name: string; type: "file" | "directory" | "link" | "other"; size: number }
        }
        """,
        example: """
        const path = "~/Documents/scratch.txt";
        const placeholder = host.readFile("placeholder.txt").trim();
        let text = "";
        host.watchFile(path, (contents) => {
          text = contents ?? "";
        });

        export default {
          render() {
            return { type: "input", value: text, placeholder, submit: "save" };
          },
          onAction(action, payload) {
            if (action === "save" && typeof payload === "string") host.writeFile(path, payload);
          },
        } satisfies Gary.Menu;
        """,
        install: { host, plugin in
            let folder = plugin.bundle.directory.path
            plugin.installAPI(host, nil, FilesRequest.methods) { call in try .now(perform(FilesRequest.parse(call, home: home, folder: folder))) }
            let queue = plugin.queue
            plugin.installHandle(host, "watchFile") { [weak plugin] call, arguments in
                let path = try call.path(0, home: home, folder: folder)
                let callback = try call.function(1, "callback", in: arguments)
                let watch = FileWatch(path, queue: queue) { text in
                    plugin?.assumeIsolated { $0.callBack(callback, [text ?? NSNull()], Trace("file")) }
                }
                return HostHandle(stop: watch.stop)
            }
        },
    )
}

private nonisolated func perform(_ request: FilesRequest) throws -> JSON {
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

private final nonisolated class FileWatch: @unchecked Sendable {
    private let path: String
    private let changed: (String?) -> Void
    private var text: String?
    private var watch: PathWatch?

    init(_ path: String, queue: DispatchQueue, changed: @escaping (String?) -> Void) {
        self.path = path
        self.changed = changed
        text = try? String(contentsOfFile: path, encoding: .utf8)
        watch = PathWatch([path, (path as NSString).deletingLastPathComponent], queue: queue) { [weak self] in self?.check() }
    }

    func stop() {
        watch?.stop()
        watch = nil
    }

    private func check() {
        let now = try? String(contentsOfFile: path, encoding: .utf8)
        guard watch != nil, now != text else { return }
        text = now
        changed(now)
    }
}
