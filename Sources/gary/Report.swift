import Foundation
import GaryCore
import GarySocket

func runReport() -> Int32 {
    print([
        environmentSummary(),
        "## gary doctor\n\n" + fenced(doctorText()),
        "## gary listPlugins\n\n" + appSection(.listPlugins),
        "## gary stats\n\n" + appSection(.stats(nil)),
        "## Log\n\n" + logSection(),
        "## Crash reports\n\n" + crashReportsSection(),
    ].joined(separator: "\n\n"))
    return 0
}

private func fenced(_ text: String) -> String {
    "```text\n\(text)\n```"
}

private func environmentSummary() -> String {
    let bundle = Bundle.main.infoDictionary
    let version = ProcessInfo.processInfo.operatingSystemVersion
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    var model = [UInt8](repeating: 0, count: size)
    sysctlbyname("hw.model", &model, &size, nil, 0)
    return "Gary \(bundle?["CFBundleShortVersionString"] as? String ?? "dev") (\(bundle?["CFBundleVersion"] as? String ?? "0")), " +
        "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion), " +
        String(decoding: model.prefix { $0 != 0 }, as: UTF8.self)
}

private func appSection(_ request: Request) -> String {
    do {
        switch try Response.decode(line: requestLine(request.line, path: Paths.socket, timeout: 10)) {
        case let .ok(list): return fenced(list)
        case let .failure(message): return "gary: \(message)"
        }
    } catch SocketError.unreachable {
        return "Gary is not running."
    } catch {
        return "gary: \(error)"
    }
}

private func logSection() -> String {
    guard let data = try? Data(contentsOf: Paths.log) else { return "No log at \(Paths.log.path)." }
    return fenced(String(decoding: data, as: UTF8.self).split(separator: "\n").suffix(100).joined(separator: "\n"))
}

private func crashReportsSection() -> String {
    let folder = Paths.userHome.appending(path: "Library/Logs/DiagnosticReports")
    let since = Date(timeIntervalSinceNow: -14 * 24 * 60 * 60)
    let reports = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
        .filter { $0.lastPathComponent.hasPrefix("gary") && $0.pathExtension == "ips" }
        .compactMap { url in
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { (name: url.lastPathComponent, date: $0) }
        }
        .filter { $0.date > since }
        .sorted { $0.date > $1.date }
        .prefix(5)
    return reports.isEmpty ? "None in the last 14 days." : reports.map { "- \($0.name) (\($0.date.ISO8601Format()))" }.joined(separator: "\n")
}
