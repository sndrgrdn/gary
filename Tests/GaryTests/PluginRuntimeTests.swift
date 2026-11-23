import Foundation
@testable import gary
import GaryCore
import Testing

final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [RuntimeEvent] = []

    func append(_ event: RuntimeEvent) {
        lock.withLock { events.append(event) }
    }

    func next() async throws -> RuntimeEvent {
        for _ in 0..<2000 {
            if let event = lock.withLock({ events.isEmpty ? nil : events.removeFirst() }) {
                return event
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw RenderError("no event")
    }

    var isEmpty: Bool {
        lock.withLock { events.isEmpty }
    }
}

final class Listener: Subscriber, @unchecked Sendable {
    private let lock = NSLock()
    private var received: [JSON] = []

    func receive(_: Topic, _ value: JSON, _: Trace) {
        lock.withLock { received.append(value) }
    }

    var values: [JSON] {
        lock.withLock { received }
    }
}

let vendor = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../Resources/vendor")

let transpiler = Transpiler(
    sucrase: vendor.appending(path: "sucrase.js"),
    cache: FileManager.default.temporaryDirectory.appending(path: "gary-tests-\(UUID().uuidString)"),
)

let engine = PluginEngine(effect: vendor.appending(path: "effect.js"))

let display = DisplayInfo(id: "main", index: 0, frame: CGRect(x: 0, y: 0, width: 1000, height: 800), band: 32)

struct Harness {
    let runtime: PluginRuntime
    let events: Events
    let hub: StateHub

    init(
        _ source: String,
        id: String = "test.runtime",
        kind: PluginKind = .barWidget,
        shown: [String] = [SurfaceAddress.main],
        subscribes: [String] = [],
        uses: [String] = [],
        files: [String: String] = [:],
        manifest fields: [String: JSON] = [:],
        engine: PluginEngine = engine,
    ) throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "gary-runtime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = JSON.object(fields.merging([
            "schemaVersion": .number(1),
            "id": .string(id),
            "name": .string("Runtime"),
            "version": .string("0.1.0"),
            "kinds": .array([.string(kind.rawValue)]),
            "entryPoints": .object([kind.rawValue: .string("main.js")]),
            "subscribes": .array(subscribes.map(JSON.string)),
            "uses": .array(uses.map(JSON.string)),
        ]) { field, _ in field })
        try Data(manifest.text.utf8).write(to: directory.appending(path: "manifest.json"))
        var files = files
        files["main.js"] = source
        for (path, text) in files {
            let url = directory.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let bundle = try PluginBundle.load(directory, origin: .user, capabilities: Capability.names())
        let events = Events()
        let hub = StateHub(sources: [:])
        runtime = PluginRuntime(
            bundle: bundle,
            kind: kind,
            scene: Scene(displays: [display], shown: Dictionary(uniqueKeysWithValues: shown.map { ($0, ShownSurface(focused: display.id)) })),
            settings: .object(["greeting": .string("hi")]),
            theme: .object(["name": .string("dark")]),
            hub: hub,
            deliver: { _, event in events.append(event) },
            engine: engine,
            transpiler: transpiler,
        )
        self.events = events
        self.hub = hub
        runtime.load(Trace("test"))
    }

    var isRunning: Bool {
        runtime.queue.sync { runtime.assumeIsolated { $0.isRunning } }
    }

    func text() async throws -> String {
        try await Self.text(of: events.next())
    }

    static func text(of event: RuntimeEvent) throws -> String {
        switch event {
        case let .loaded(output, _), let .output(output, _):
            guard case let .text(text)? = output.trees[SurfaceAddress.main]?[display.id]??.content else {
                throw RenderError("no text in \(output)")
            }
            return text
        case let .failed(reason):
            throw RenderError("failed: \(reason)")
        case .surface, .call:
            throw RenderError("unexpected \(event)")
        }
    }

    func failure() async throws -> String {
        guard case let .failed(reason) = try await events.next() else { throw RenderError("expected a failure") }
        return reason
    }
}

func widget(_ members: String = "", setup: String = "") -> String {
    """
    var count = 0;
    \(setup)
    export default {
      render: function (state) { return { type: "text", text: String(count) }; },
      \(members)
    };
    """
}

struct PluginRuntimeTests {
    @Test func `the host offers only the capabilities the manifest uses`() async throws {
        let setup = "count = typeof host.exec + \" \" + typeof host.power;"
        let bare = try Harness(widget(setup: setup))
        #expect(try await bare.text() == "undefined undefined")
        bare.runtime.stop()
        let exec = try Harness(widget(setup: setup), uses: ["exec"])
        #expect(try await exec.text() == "function undefined")
        exec.runtime.stop()
    }

    @Test func `renders each display with the state settings theme and display`() async throws {
        let harness = try Harness("""
        export default {
          render: function (state) {
            return { type: "text", text: [state.settings.greeting, state.theme.name, state.display.id].join(" ") };
          },
        };
        """)
        #expect(try await harness.text() == "hi dark main")
        harness.runtime.setTheme(.object(["name": .string("light")]), Trace("test"))
        #expect(try await harness.text() == "hi light main")
        harness.runtime.stop()
    }

    @Test func `a hidden scene loads with no output`() async throws {
        let harness = try Harness(widget(), shown: [])
        guard case let .loaded(output, _) = try await harness.events.next() else { throw RenderError("expected loaded") }
        #expect(output == RuntimeOutput())
        harness.runtime.stop()
    }

    @Test func `a service loads without a render function`() async throws {
        let harness = try Harness("export default { methods: {} };", kind: .service, shown: [])
        guard case .loaded = try await harness.events.next() else { throw RenderError("expected loaded") }
        harness.runtime.stop()
    }

    @Test func `a missing render function fails the load`() async throws {
        let harness = try Harness("export default {};", shown: [])
        #expect(try await harness.failure() == "Error: the default export has no render function")
    }

    @Test func `actions run the handler with the payload and rerender`() async throws {
        let harness = try Harness(widget("onAction: function (name, payload, state) { count += payload.by; },"))
        #expect(try await harness.text() == "0")
        harness.runtime.perform("add", .object(["by": .number(2)]))
        #expect(try await harness.text() == "2")
        harness.runtime.stop()
    }

    @Test func `an unhandled key reaches the fallback and a handled one does not`() async throws {
        let harness = try Harness(widget("onKey: function (key) { count += 1; return key === \"up\"; },"))
        #expect(try await harness.text() == "0")
        let unhandled = Events()
        harness.runtime.key("up") { unhandled.append(.failed("up")) }
        #expect(try await harness.text() == "1")
        harness.runtime.key("down") { unhandled.append(.failed("down")) }
        #expect(try await harness.text() == "2")
        guard case let .failed(key) = try await unhandled.next() else { throw RenderError("expected the fallback") }
        #expect(key == "down")
        try await Task.sleep(for: .milliseconds(50))
        #expect(unhandled.isEmpty)
        harness.runtime.stop()
    }

    @Test func `timers fire once or repeat until cleared`() async throws {
        let harness = try Harness(widget(setup: """
        setTimeout(function (by) { count += by; }, 5, 10);
        var interval = setInterval(function () { count += 1; if (count === 12) clearInterval(interval); }, 10);
        var cancelled = setTimeout(function () { count += 100; }, 5);
        clearTimeout(cancelled);
        """))
        #expect(try await harness.text() == "0")
        var seen = ["0"]
        while seen.last != "12" {
            try await seen.append(harness.text())
        }
        try await Task.sleep(for: .milliseconds(60))
        #expect(harness.events.isEmpty)
        #expect(seen.contains("10"))
        harness.runtime.stop()
    }

    @Test func `host call resolves with the parsed reply and rejects with the error message`() async throws {
        let harness = try Harness(widget("""
        render: function () { return { type: "text", text: shown }; },
        onAction: function (name) {
          host.call(name, 1, "two").then(
            function (value) { shown = "ok " + JSON.stringify(value); },
            function (error) { shown = (error instanceof Error) + " " + error.message; }
          );
        },
        """, setup: "var shown = \"start\";"))
        #expect(try await harness.text() == "start")
        harness.runtime.perform("good", .null)
        guard case let .call(target, method, arguments, reply) = try await harness.events.next() else { throw RenderError("expected a call") }
        #expect(target.plugin == nil && target.kind == nil)
        #expect(method == "good")
        #expect(arguments == ["1", "two"])
        reply(.ok(#"{"a":1}"#))
        #expect(try await harness.text() == #"ok {"a":1}"#)
        harness.runtime.perform("empty", .null)
        guard case let .call(_, _, _, replyEmpty) = try await harness.events.next() else { throw RenderError("expected a call") }
        replyEmpty(.ok(""))
        #expect(try await harness.text() == "ok undefined")
        harness.runtime.perform("bad", .null)
        guard case let .call(_, _, _, replyBad) = try await harness.events.next() else { throw RenderError("expected a call") }
        replyBad(.failure("nope"))
        #expect(try await harness.text() == "true nope")
        harness.runtime.stop()
    }

    @Test func `methods reply with their JSON result or their error`() async throws {
        let harness = try Harness(widget("""
        methods: {
          sum: function (a, b) { return Number(a) + Number(b); },
          none: function () {},
          later: function (a) { return Promise.resolve({ echo: a }); },
          broken: function () { return Promise.reject(new Error("broke")); }
        },
        """))
        #expect(try await harness.text() == "0")
        let replies = Events()
        for (method, arguments) in [("sum", ["1", "2"]), ("none", []), ("later", ["x"]), ("broken", []), ("missing", [])] {
            harness.runtime.call(method, arguments) { response in
                switch response {
                case let .ok(text): replies.append(.failed("ok \(text)"))
                case let .failure(text): replies.append(.failed("failure \(text)"))
                }
            }
        }
        var texts: [String] = []
        for _ in 0..<5 {
            guard case let .failed(text) = try await replies.next() else { throw RenderError("expected a reply") }
            texts.append(text)
        }
        #expect(texts.sorted() == ["failure Error: no method missing", "failure broke", "ok ", "ok 3", #"ok {"echo":"x"}"#])
        harness.runtime.stop()
    }

    @Test func `publish shares JSON on the plugin topic and surface requests reach the shell`() async throws {
        let harness = try Harness(widget("""
        onAction: function (name) {
          if (name === "publish") host.publish({ n: 1 });
          else host[name]();
        },
        """))
        #expect(try await harness.text() == "0")
        let listener = Listener()
        _ = harness.hub.subscribe(listener, to: [.plugin(harness.runtime.id)])
        harness.runtime.perform("publish", .null)
        for request in [SurfaceRequest.show, .hide, .toggle] {
            harness.runtime.perform(request.rawValue, .null)
            guard case let .surface(next, surface, _) = try await harness.events.next() else { throw RenderError("expected \(request)") }
            #expect(next == request && surface == SurfaceAddress(harness.runtime.id))
        }
        #expect(listener.values == [.object(["n": .number(1)])])
        harness.runtime.stop()
    }

    @Test func `a surface request carries the clicked node's frame only while onAction runs for that click`() async throws {
        let harness = try Harness(widget("""
        onAction: function (name) {
          if (name === "now") host.show();
          if (name === "later") setTimeout(function () { host.toggle(); }, 1);
        },
        onHotkey: function () { host.show(); },
        """))
        #expect(try await harness.text() == "0")
        let origin = CGRect(x: 10, y: 700, width: 40, height: 24)
        func next() async throws -> (SurfaceRequest, CGRect?) {
            guard case let .surface(request, _, origin) = try await harness.events.next() else { throw RenderError("expected a surface request") }
            return (request, origin)
        }
        harness.runtime.perform("now", .null, origin: origin)
        #expect(try await next() == (.show, origin))
        harness.runtime.perform("later", .null, origin: origin)
        #expect(try await next() == (.toggle, nil))
        harness.runtime.hotkey("open")
        #expect(try await next() == (.show, nil))
        harness.runtime.perform("now", .null)
        #expect(try await next() == (.show, nil))
        harness.runtime.stop()
    }

    @Test func `a node scroll reaches onScroll with the node's action and frame`() async throws {
        let harness = try Harness(widget("""
        onScroll: function (event) {
          count = event.action === undefined ? event.y : event.action + " " + event.y;
          if (event.action) host.show();
        },
        """))
        #expect(try await harness.text() == "0")
        let origin = CGRect(x: 10, y: 700, width: 40, height: 24)
        harness.runtime.scroll(.object(["y": .number(-2)]))
        #expect(try await harness.text() == "-2")
        harness.runtime.scroll(.object(["y": .number(3)]), action: "volume", origin: origin)
        guard case let .surface(request, _, shownAt) = try await harness.events.next() else { throw RenderError("expected a surface request") }
        #expect(request == .show && shownAt == origin)
        #expect(try await harness.text() == "volume 3")
        harness.runtime.stop()
    }

    @Test func `subscribed topics reach onTopic and the state`() async throws {
        let harness = try Harness(widget("""
        onTopic: function (event, state) { seen.push(event.topic + "=" + JSON.stringify(event.value) + "/" + JSON.stringify(state[event.topic])); },
        render: function () { return { type: "text", text: seen.join(",") }; },
        """, setup: "var seen = [];"), subscribes: ["test.other"])
        #expect(try await harness.text().isEmpty)
        try harness.hub.publish(.plugin(#require(PluginID("test.other"))), .number(7), Trace("test"))
        #expect(try await harness.text() == "test.other=7/7")
        try harness.hub.publish(.plugin(#require(PluginID("test.other"))), .array([.string("a\"b")]), Trace("test"))
        #expect(try await harness.text() == #"test.other=7/7,test.other=["a\"b"]/["a\"b"]"#)
        harness.runtime.stop()
    }

    @Test func `a throwing render fails with the exception`() async throws {
        let harness = try Harness("export default { render: function () { throw new Error(\"boom\"); } };")
        #expect(try await harness.failure() == "Error: boom")
    }

    @Test(.enabled(if: ShaderProgram.device != nil, "this Mac has no Metal device"))
    func `a shader file keeps only its latest program and none after its plugin stops`() async throws {
        let harness = try Harness(widget(), id: "test.shaders")
        _ = try await harness.text()
        let file = FileManager.default.temporaryDirectory.appending(path: "gary-shader-\(UUID().uuidString).metal")
        try Data("half4 fill(float2 position, float2 size, float time, constant float *args, uint count) { return half4(1); }".utf8).write(to: file)
        let saved = try #require(FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
        let shader = Node.Shader(path: file.path, function: "fill")
        func compile(modified: Date) async throws -> ShaderProgram {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
            return try #require(await ShaderCache.shared.program(shader, plugin: harness.runtime.id))
        }
        let first = try await compile(modified: saved)
        #expect(try await compile(modified: saved) === first)
        let touched = try await compile(modified: saved.addingTimeInterval(60))
        #expect(touched !== first)
        #expect(try await compile(modified: saved) !== first)
        let latest = try await compile(modified: saved)
        harness.runtime.stop()
        #expect(!harness.isRunning)
        #expect(try await compile(modified: saved) !== latest)
    }
}
