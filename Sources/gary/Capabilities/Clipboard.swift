import AppKit
import GaryCore

extension Capability {
    static let clipboard = Capability(
        name: "clipboard",
        summary: "A clipboard change counter and the types on the clipboard. Read the clipboard and write text to it.",
        types: """
        declare namespace Gary {
          interface State { clipboard?: ClipboardChange }
          interface ClipboardChange { count: number; types: string[]; access: "default" | "ask" | "always" | "never" }
          interface ClipboardContents { count: number; text: string | null; image: string | null; files: string[] }
          interface Host { clipboard: ClipboardApi }
          interface ClipboardApi {
            read(): Promise<ClipboardContents>;
            writeText(text: string): { count: number };
          }
        }
        """,
        example: """
        const history: string[] = [];

        export default {
          onTopic(topic) {
            if (topic !== "clipboard") return;
            host.clipboard.read().then((contents) => {
              if (contents.text && contents.text !== history[0]) history.unshift(contents.text);
            });
          },
          render() {
            return { type: "column", children: history.slice(0, 8).map((text, index) => ({ type: "text", key: String(index), text, action: text })) };
          },
          onAction(text) {
            host.clipboard.writeText(text);
          },
        } satisfies Gary.Menu;
        """,
        install: { host, plugin in
            plugin.installAPI(host, "clipboard", ClipboardRequest.methods) { call in
                switch try ClipboardRequest.parse(call) {
                case .read:
                    return .later(.global(qos: .userInitiated)) { try readClipboard() }
                case let .writeText(text):
                    let board = NSPasteboard.general
                    board.clearContents()
                    board.setString(text, forType: .string)
                    return .now(.object(["count": .number(Double(board.changeCount))]))
                }
            }
        },
        topic: { ClipboardTopic($0) },
    )
}

private final class ClipboardTopic: TopicFeed {
    private let publish: (JSON, Trace) -> Void
    private var count = -1
    private var observation: Observation?

    init(_ publish: @escaping (JSON, Trace) -> Void) {
        self.publish = publish
        check()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.check() }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        observation = Observation { timer.invalidate() }
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

private func readClipboard() throws -> JSON {
    let board = NSPasteboard.general
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
