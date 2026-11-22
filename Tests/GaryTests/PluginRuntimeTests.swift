import Foundation
@testable import gary
import GaryCore
import Testing

private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [RuntimeEvent] = []

    func append(_ event: RuntimeEvent) {
        lock.withLock { events.append(event) }
    }

    func next() async throws -> RuntimeEvent {
        for _ in 0..<400 {
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

private final class Listener: Subscriber, @unchecked Sendable {
    private let lock = NSLock()
    private var received: [JSON] = []

    func receive(_: Topic, _ value: JSON, _: Trace) {
        lock.withLock { received.append(value) }
    }

    var values: [JSON] {
        lock.withLock { received }
    }
}

private let display = DisplayInfo(id: "main", index: 0, frame: CGRect(x: 0, y: 0, width: 1000, height: 800), band: 32)

private struct Harness {
    let runtime: PluginRuntime
    let events: Events
    let hub: StateHub

    init(_ source: String, id: String = "test.runtime", kind: PluginKind = .barWidget, shown: Bool = true, subscribes: [String] = []) throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "gary-runtime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = JSON.object([
            "schemaVersion": .number(1),
            "id": .string(id),
            "name": .string("Runtime"),
            "version": .string("0.1.0"),
            "kinds": .array([.string(kind.rawValue)]),
            "entryPoints": .object([kind.rawValue: .string("main.js")]),
            "subscribes": .array(subscribes.map(JSON.string)),
        ])
        try Data(manifest.text.utf8).write(to: directory.appending(path: "manifest.json"))
        try Data(source.utf8).write(to: directory.appending(path: "main.js"))
        let bundle = try PluginBundle.load(directory, origin: .user, capabilities: Capability.names())
        let events = Events()
        let hub = StateHub(sources: [:])
        runtime = PluginRuntime(
            bundle: bundle,
            kind: kind,
            scene: Scene(displays: [display], shown: shown, focused: display.id),
            settings: .object(["greeting": .string("hi")]),
            theme: .object(["name": .string("dark")]),
            hub: hub,
            deliver: { _, event in events.append(event) },
        )
        self.events = events
        self.hub = hub
        runtime.load(Trace("test"))
    }

    func text() async throws -> String {
        try await Self.text(of: events.next())
    }

    static func text(of event: RuntimeEvent) throws -> String {
        switch event {
        case let .loaded(output, _), let .output(output, _):
            guard let node = output.trees[display.id], case let .text(text) = node.content else { throw RenderError("no text in \(output)") }
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

private func widget(_ body: String) -> String {
    """
    var count = 0;
    \(body)
    module.exports.render = module.exports.render || function (state) {
      return { type: "text", text: String(count) };
    };
    """
}

struct PluginRuntimeTests {
    @Test func `renders each display with the state settings theme and display`() async throws {
        let harness = try Harness("""
        module.exports.render = function (state) {
          return { type: "text", text: [state.settings.greeting, state.theme.name, state.display.id].join(" ") };
        };
        """)
        #expect(try await harness.text() == "hi dark main")
        harness.runtime.stop()
    }

    @Test func `a hidden scene loads with no output`() async throws {
        let harness = try Harness(widget(""), shown: false)
        guard case let .loaded(output, _) = try await harness.events.next() else { throw RenderError("expected loaded") }
        #expect(output == RuntimeOutput())
        harness.runtime.stop()
    }

    @Test func `a service loads without a render function`() async throws {
        let harness = try Harness("module.exports.methods = {};", kind: .service, shown: false)
        guard case .loaded = try await harness.events.next() else { throw RenderError("expected loaded") }
        harness.runtime.stop()
    }

    @Test func `a missing render function fails the load`() async throws {
        let harness = try Harness("", shown: false)
        #expect(try await harness.failure() == "Error: module.exports.render is not a function")
    }

    @Test func `actions run the handler with the payload and rerender`() async throws {
        let harness = try Harness(widget("module.exports.onAction = function (name, payload, state) { count += payload.by; };"))
        #expect(try await harness.text() == "0")
        harness.runtime.perform("add", .object(["by": .number(2)]))
        #expect(try await harness.text() == "2")
        harness.runtime.stop()
    }

    @Test func `an unhandled key reaches the fallback and a handled one does not`() async throws {
        let harness = try Harness(widget("module.exports.onKey = function (key) { count += 1; return key === \"up\"; };"))
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
        let harness = try Harness(widget("""
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
        var shown = "start";
        module.exports.render = function () { return { type: "text", text: shown }; };
        module.exports.onAction = function (name) {
          host.call(name, 1, "two").then(
            function (value) { shown = "ok " + JSON.stringify(value); },
            function (error) { shown = (error instanceof Error) + " " + error.message; }
          );
        };
        """))
        #expect(try await harness.text() == "start")
        harness.runtime.perform("good", .null)
        guard case let .call(method, arguments, reply) = try await harness.events.next() else { throw RenderError("expected a call") }
        #expect(method == "good")
        #expect(arguments == ["1", "two"])
        reply(.ok(#"{"a":1}"#))
        #expect(try await harness.text() == #"ok {"a":1}"#)
        harness.runtime.perform("empty", .null)
        guard case let .call(_, _, replyEmpty) = try await harness.events.next() else { throw RenderError("expected a call") }
        replyEmpty(.ok(""))
        #expect(try await harness.text() == "ok undefined")
        harness.runtime.perform("bad", .null)
        guard case let .call(_, _, replyBad) = try await harness.events.next() else { throw RenderError("expected a call") }
        replyBad(.failure("nope"))
        #expect(try await harness.text() == "true nope")
        harness.runtime.stop()
    }

    @Test func `methods reply with their JSON result or their error`() async throws {
        let harness = try Harness(widget("""
        module.exports.methods = {
          sum: function (a, b) { return Number(a) + Number(b); },
          none: function () {},
          later: function (a) { return Promise.resolve({ echo: a }); },
          broken: function () { return Promise.reject(new Error("broke")); }
        };
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
        module.exports.onAction = function (name) {
          if (name === "publish") host.publish({ n: 1 });
          else host[name]();
        };
        """))
        #expect(try await harness.text() == "0")
        let listener = Listener()
        _ = harness.hub.subscribe(listener, to: [.plugin(harness.runtime.id)])
        harness.runtime.perform("publish", .null)
        for request in [SurfaceRequest.show, .hide, .toggle] {
            harness.runtime.perform(request.rawValue, .null)
            guard case let .surface(next, _) = try await harness.events.next() else { throw RenderError("expected \(request)") }
            #expect(next == request)
        }
        #expect(listener.values == [.object(["n": .number(1)])])
        harness.runtime.stop()
    }

    @Test func `a surface request carries the clicked node's frame only while onAction runs for that click`() async throws {
        let harness = try Harness(widget("""
        module.exports.onAction = function (name) {
          if (name === "now") host.show();
          if (name === "later") setTimeout(function () { host.toggle(); }, 1);
        };
        module.exports.onHotkey = function () { host.show(); };
        """))
        #expect(try await harness.text() == "0")
        let origin = CGRect(x: 10, y: 700, width: 40, height: 24)
        func next() async throws -> (SurfaceRequest, CGRect?) {
            guard case let .surface(request, origin) = try await harness.events.next() else { throw RenderError("expected a surface request") }
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
        module.exports.onScroll = function (event) {
          count = event.action === undefined ? event.y : event.action + " " + event.y;
          if (event.action) host.show();
        };
        """))
        #expect(try await harness.text() == "0")
        let origin = CGRect(x: 10, y: 700, width: 40, height: 24)
        harness.runtime.scroll(.object(["y": .number(-2)]))
        #expect(try await harness.text() == "-2")
        harness.runtime.scroll(.object(["y": .number(3)]), action: "volume", origin: origin)
        guard case let .surface(request, shownAt) = try await harness.events.next() else { throw RenderError("expected a surface request") }
        #expect(request == .show && shownAt == origin)
        #expect(try await harness.text() == "volume 3")
        harness.runtime.stop()
    }

    @Test func `subscribed topics reach onTopic and the state`() async throws {
        let harness = try Harness(widget("""
        var seen = [];
        module.exports.onTopic = function (topic, value, state) { seen.push(topic + "=" + JSON.stringify(state[topic])); };
        module.exports.render = function () { return { type: "text", text: seen.join(",") }; };
        """), subscribes: ["test.other"])
        #expect(try await harness.text().isEmpty)
        try harness.hub.publish(.plugin(#require(PluginID("test.other"))), .number(7), Trace("test"))
        #expect(try await harness.text() == "test.other=7")
        harness.runtime.stop()
    }

    @Test func `surfaces resolve their spec from the module`() async throws {
        let harness = try Harness(widget("module.exports.surface = function (state) { return { width: 300, height: 200 }; };"), kind: .panel)
        guard case let .loaded(output, _) = try await harness.events.next() else { throw RenderError("expected loaded") }
        #expect(output.surface?.width == .points(300))
        #expect(output.trees.keys.sorted() == [display.id])
        harness.runtime.stop()
    }

    @Test func `a throwing render fails with the exception`() async throws {
        let harness = try Harness("module.exports.render = function () { throw new Error(\"boom\"); };")
        #expect(try await harness.failure() == "Error: boom")
    }

    @Test func `a script that runs past the time limit is stopped`() async throws {
        let harness = try Harness("module.exports.render = function () { for (;;) {} };")
        #expect(try await harness.failure() == "stopped after running longer than 100 ms")
    }

    @Test(.enabled(if: ShaderProgram.device != nil, "this Mac has no Metal device"))
    func `a shader file keeps only its latest program and none after its plugin stops`() async throws {
        let harness = try Harness(widget(""), id: "test.shaders")
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
        #expect(harness.runtime.queue.sync { !harness.runtime.isRunning })
        #expect(try await compile(modified: saved) !== latest)
    }
}
