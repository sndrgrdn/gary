import Foundation
import JavaScriptCore

private let fetchSession = URLSession(configuration: .ephemeral)

extension Capability {
    static let network = Capability(name: "network", summary: "A global fetch for http and https URLs.", types: """
    declare namespace Gary {
      interface FetchResponse { status: number; text: string }
    }
    declare function fetch(url: string): Promise<Gary.FetchResponse>;
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
        let fetch: @convention(block) (String) -> JSValue? = { [weak plugin] address in
            guard let context = JSContext.current() else { return nil }
            return JSValue(newPromiseIn: context) { resolve, reject in
                guard let resolve, let reject else { return }
                guard let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased()) else {
                    reject.call(withArguments: [context.newError("fetch takes an http or https URL")])
                    return
                }
                if let plugin {
                    load(url, resolve, reject, into: plugin)
                }
            }
        }
        host.context.setObject(fetch, forKeyedSubscript: "fetch" as NSString)
    })
}

private func load(_ url: URL, _ resolve: JSValue, _ reject: JSValue, into plugin: PluginRuntime) {
    fetchSession.dataTask(with: URLRequest(url: url, timeoutInterval: 15)) { [weak plugin] data, response, error in
        plugin?.queue.async {
            if let error {
                plugin?.callBack(reject, [resolve.context.newError("fetch failed: \(error.localizedDescription)")], Trace("fetch"))
            } else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                plugin?.callBack(resolve, [["status": status, "text": String(decoding: data ?? Data(), as: UTF8.self)]], Trace("fetch"))
            }
        }
    }.resume()
}
