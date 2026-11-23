import Foundation
@testable import gary
import GaryCore
import Testing

@MainActor struct DoctorTests {
    private static func files(in folder: URL) -> ConfigFiles {
        ConfigFiles(
            shellConfig: folder.appending(path: "shell.json"),
            palette: folder.appending(path: "palette.toml"),
            userTheme: folder.appending(path: "theme.json"),
            defaultTheme: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../Resources/theme.json"),
            builtinPlugins: folder.appending(path: "builtin"),
            userPlugins: folder.appending(path: "plugins"),
        )
    }

    @Test(arguments: [Palette.Mode.light, .dark])
    func `checks the theme in the Mac's appearance`(system: Palette.Mode) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "gary-doctor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let report = Doctor.report(nil, system: system, files: Self.files(in: folder))
        #expect(report.contains("  ok    built-in theme in \(system.rawValue) mode"))
    }

    @Test func `checks the theme that gary applyTheme applied`() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "gary-doctor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let applied = try JSON.parse(#"{"colors":{"mine":"no-such-colour"}}"#)
        let runtime = DoctorRuntime(pid: 1, enabled: [], pluginStates: [], themePayload: applied)
        let report = Doctor.report(runtime, system: .dark, files: Self.files(in: folder))
        #expect(report.contains("  FAIL  theme: colors.mine"))
    }
}
