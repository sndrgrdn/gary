import Foundation
@testable import gary
import GaryCore
import Testing

@MainActor struct DoctorTests {
    @Test(arguments: [Palette.Mode.light, .dark])
    func `checks the theme in the Mac's appearance`(system: Palette.Mode) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "gary-doctor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = ConfigFiles(
            shellConfig: folder.appending(path: "shell.json"),
            palette: folder.appending(path: "palette.toml"),
            userTheme: folder.appending(path: "theme.json"),
            defaultTheme: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../Resources/theme.json"),
            builtinPlugins: folder.appending(path: "builtin"),
            userPlugins: folder.appending(path: "plugins"),
        )
        let report = Doctor.report(nil, system: system, files: files)
        #expect(report.contains("  ok    built-in theme in \(system.rawValue) mode"))
    }
}
