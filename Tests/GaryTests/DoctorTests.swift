import Foundation
@testable import gary
import GaryCore
import Testing

@MainActor struct DoctorTests {
    private let folder = ConfigFolder()

    @Test(arguments: [Palette.Mode.light, .dark])
    func `checks the theme in the Mac's appearance`(system: Palette.Mode) {
        let report = Doctor.report(nil, system: system, files: folder.files)
        #expect(report.contains("  ok    built-in theme in \(system.rawValue) mode"))
    }

    @Test func `checks the theme that gary applyTheme applied`() throws {
        let applied = try JSON.parse(#"{"colors":{"mine":"no-such-colour"}}"#)
        let runtime = DoctorRuntime(pid: 1, enabled: [], pluginStates: [], themePayload: applied)
        let report = Doctor.report(runtime, system: .dark, files: folder.files)
        #expect(report.contains("  FAIL  theme: colors.mine"))
    }
}
