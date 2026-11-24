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

    @Test func `flags a supervised Gary whose JavaScriptCore missed the system allocator`() {
        let report = { (supervised: Bool, zones: [String]) in
            Doctor.report(
                DoctorRuntime(pid: 1, enabled: [], pluginStates: [], supervised: supervised, allocatorZones: zones),
                system: .dark, files: folder.files,
            )
        }
        #expect(report(true, ["DefaultMallocZone", "WebKit Using System Malloc"]).contains("  ok    JavaScriptCore runs on the system allocator"))
        #expect(report(true, ["DefaultMallocZone", "WebKit Malloc"]).contains("  FAIL  JavaScriptCore runs on its own allocator"))
        #expect(report(false, ["DefaultMallocZone"]).contains("  -     JavaScriptCore runs on its own allocator"))
    }
}
