import Foundation
import GaryCore
@preconcurrency import JavaScriptCore

private nonisolated let fetchSession = URLSession(configuration: .ephemeral)

nonisolated extension Capability {
    static let network = Capability(name: "network", summary: "A global fetch for http and https URLs.", types: """
    declare namespace Gary {
      type FetchOptions = { method?: string; headers?: { [name: string]: string }; body?: string }
      type FetchResponse = { status: number; text: string }
    }
    declare function fetch(url: string, options?: Gary.FetchOptions): Promise<Gary.FetchResponse>;
    """, example: """
    let temperature = "…";

    function refresh() {
      fetch("https://wttr.in/?format=%t").then((response) => {
        temperature = response.status === 200 ? response.text.trim() : "?";
      });
    }
    refresh();
    setInterval(refresh, 15 * 60_000);

    export default {
      render() {
        return { type: "text", text: temperature };
      },
    } satisfies Gary.BarWidget;
    """, install: { host, plugin in
        let fetch: @convention(block) (String) -> JSValue? = { [weak plugin] text in
            guard let context = JSContext.current() else { return nil }
            return JSValue(newPromiseIn: context) { resolve, reject in
                guard let resolve, let reject else { return }
                do {
                    let request = try FetchRequest.parse((try? JSON.parse(text))?.array ?? [])
                    if let plugin {
                        load(request, resolve, reject, into: plugin)
                    }
                } catch {
                    reject.call(withArguments: [context.newError(String(describing: error))])
                }
            }
        }
        host.context.evaluateScript("""
        (function (bridge) {
          globalThis.fetch = function () {
            return bridge(JSON.stringify(Array.prototype.slice.call(arguments)));
          };
        })
        """).call(withArguments: [fetch])
    })
}

private nonisolated func load(_ request: FetchRequest, _ resolve: JSValue, _ reject: JSValue, into plugin: PluginRuntime) {
    var urlRequest = URLRequest(url: request.url, timeoutInterval: 15)
    urlRequest.httpMethod = request.method
    for (name, value) in request.headers {
        urlRequest.setValue(value, forHTTPHeaderField: name)
    }
    urlRequest.httpBody = request.body.map { Data($0.utf8) }
    plugin.metrics.hostCallStarted("fetch")
    let note = HostCallNote(plugin, "fetch")
    fetchSession.dataTask(with: urlRequest) { [weak plugin] data, response, error in
        plugin?.metrics.hostCallFinished("fetch")
        let trace = Trace("fetch")
        note.finished(trace, ok: error == nil)
        plugin?.onQueue { runtime in
            if let error {
                runtime.callBack(reject, [resolve.context.newError("fetch failed: \(error.localizedDescription)")], trace)
            } else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                runtime.callBack(resolve, [["status": status, "text": String(decoding: data ?? Data(), as: UTF8.self)]], trace)
            }
        }
    }.resume()
}
