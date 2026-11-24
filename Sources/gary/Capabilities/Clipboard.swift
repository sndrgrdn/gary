import AppKit
import GaryCore

nonisolated extension Capability {
    static let clipboard = Capability(
        name: "clipboard",
        summary: """
        A clipboard change counter and the types on the clipboard. Read the clipboard, and write text, an image, or files to it. \
        Text written as concealed, such as a password, carries `org.nspasteboard.ConcealedType`, so clipboard managers skip it.
        """,
        types: """
        declare namespace Gary {
          type ClipboardChange = { count: number; types: string[]; access: "default" | "ask" | "always" | "never" }
          type ClipboardContents = { count: number; text: string | null; image: string | null; files: string[] }
          interface Host { clipboard: ClipboardApi }
          interface ClipboardApi {
            read(): Promise<ClipboardContents>;
            writeText(text: string, concealed?: boolean): { count: number };
            writeImage(path: string): { count: number };
            writeFiles(paths: string[]): { count: number };
          }
        }
        """,
        example: """
        type Entry = { text: string } | { image: string } | { files: string[] };
        const history: Entry[] = [];

        export default {
          onTopic({ topic }) {
            if (topic !== "clipboard") return;
            host.clipboard.read().then((contents) => {
              if (contents.files.length > 0) history.unshift({ files: contents.files });
              else if (contents.image) history.unshift({ image: contents.image });
              else if (contents.text) history.unshift({ text: contents.text });
            });
          },
          render() {
            return {
              type: "column",
              children: history.slice(0, 8).map((entry, index): Gary.Node => "image" in entry
                ? { type: "image", key: String(index), path: entry.image, height: 48, action: String(index) }
                : { type: "text", key: String(index), text: "text" in entry ? entry.text : entry.files.join(", "), action: String(index) }),
            };
          },
          onAction(index) {
            const entry = history[Number(index)];
            if (!entry) return;
            if ("image" in entry) host.clipboard.writeImage(entry.image);
            else if ("files" in entry) host.clipboard.writeFiles(entry.files);
            else host.clipboard.writeText(entry.text);
          },
        } satisfies Gary.Menu;
        """,
        install: { host, plugin in
            let folder = plugin.bundle.directory.path
            plugin.installAPI(host, "clipboard", ClipboardRequest.methods) { call in
                switch try ClipboardRequest.parse(call, home: home, folder: folder) {
                case .read: .later(.global(qos: .userInitiated)) { try readClipboard(.general) }
                case let .write(content): try .now(writeClipboard(content, to: .general))
                }
            }
        },
        topic: CapabilityTopic(type: "ClipboardChange") { ClipboardTopic($0) },
    )
}

private final nonisolated class ClipboardTopic: TopicFeed, @unchecked Sendable {
    private let publish: @Sendable (JSON, Trace) -> Void
    private let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "gary.clipboard"))
    private var count = -1

    init(_ publish: @escaping @Sendable (JSON, Trace) -> Void) {
        self.publish = publish
        timer.setEventHandler { [weak self] in self?.check() }
        timer.schedule(deadline: .now(), repeating: 0.5, leeway: .milliseconds(250))
        timer.resume()
    }

    deinit {
        timer.cancel()
    }

    private func check() {
        let board = NSPasteboard.general
        guard board.changeCount != count else { return }
        count = board.changeCount
        publish(.object([
            "count": .number(Double(count)),
            "types": .array((board.types ?? []).map { .string($0.rawValue) }),
            "access": .string(["default", "ask", "always", "never"][max(0, min(3, board.accessBehavior.rawValue))]),
        ]), Trace("clipboard"))
    }
}

nonisolated func writeClipboard(_ content: ClipboardContent, to board: NSPasteboard) throws -> JSON {
    switch content {
    case let .text(text, concealed):
        board.clearContents()
        board.setString(text, forType: .string)
        if concealed {
            board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        }
    case let .image(path):
        guard let tiff = NSImage(contentsOfFile: path)?.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { throw HostFailure("\(path) is not an image file") }
        board.clearContents()
        board.setData(png, forType: .png)
        board.setData(tiff, forType: .tiff)
    case let .files(paths):
        if let missing = paths.first(where: { !FileManager.default.fileExists(atPath: $0) }) {
            throw HostFailure("no file at \(missing)")
        }
        board.clearContents()
        board.writeObjects(paths.map { URL(fileURLWithPath: $0) as NSURL })
    }
    return .object(["count": .number(Double(board.changeCount))])
}

nonisolated func readClipboard(_ board: NSPasteboard) throws -> JSON {
    let count = board.changeCount
    let files = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []).map(\.path)
    var image: String?
    if files.isEmpty, let data = board.data(forType: .png) ?? board.data(forType: .tiff) {
        guard let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
        else { throw HostFailure("the clipboard image cannot be read") }
        image = try savePNG(png, in: "clipboard")
    }
    return .object([
        "count": .number(Double(count)),
        "text": board.string(forType: .string).map(JSON.string) ?? .null,
        "image": image.map(JSON.string) ?? .null,
        "files": .array(files.map(JSON.string)),
    ])
}
