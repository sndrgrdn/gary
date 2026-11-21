import Foundation
import GaryCore
import JavaScriptCore

private let fetchSession = URLSession(configuration: .ephemeral)

extension PluginRuntime {
    func installFetch(in context: JSContext) {
        let fetch: @convention(block) (String) -> JSValue = { [weak self] address in
            let context = JSContext.current()!
            return JSValue(newPromiseIn: context) { resolve, reject in
                guard let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased()) else {
                    reject?.call(withArguments: [JSValue(newErrorFromMessage: "fetch takes an http or https URL", in: context)!])
                    return
                }
                self?.fetch(url, resolve!, reject!)
            }
        }
        context.setObject(fetch, forKeyedSubscript: "fetch" as NSString)
    }

    private func fetch(_ url: URL, _ resolve: JSValue, _ reject: JSValue) {
        fetchSession.dataTask(with: URLRequest(url: url, timeoutInterval: 15)) { [weak self] data, response, error in
            self?.queue.async { [weak self] in
                guard let self, functions != nil else { return }
                if let error {
                    callBack(reject, [JSValue(newErrorFromMessage: "fetch failed: \(error.localizedDescription)", in: resolve.context)!], Trace("fetch"))
                } else {
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    callBack(resolve, [["status": status, "text": String(decoding: data ?? Data(), as: UTF8.self)]], Trace("fetch"))
                }
            }
        }.resume()
    }
}
