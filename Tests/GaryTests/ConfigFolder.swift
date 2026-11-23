import Foundation
@testable import gary

final class ConfigFolder {
    let url = FileManager.default.temporaryDirectory.appending(path: "gary-config-\(UUID().uuidString)")

    var files: ConfigFiles {
        ConfigFiles(
            shellConfig: url.appending(path: "shell.json"),
            palette: url.appending(path: "palette.toml"),
            userTheme: url.appending(path: "theme.json"),
            defaultTheme: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../Resources/theme.json"),
            builtinPlugins: url.appending(path: "builtin"),
            userPlugins: url.appending(path: "plugins"),
        )
    }

    func write(_ path: String, _ text: String) throws {
        let file = url.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    func remove(_ path: String) throws {
        try FileManager.default.removeItem(at: url.appending(path: path))
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
