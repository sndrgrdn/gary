import Foundation
import GaryCore

final class CurrentTheme {
    private let files: ConfigFiles
    private(set) var value: Theme
    private(set) var palette: PaletteFile?
    private(set) var system: Palette.Mode
    private(set) var payload: JSON?

    init(files: ConfigFiles, system: Palette.Mode) throws {
        self.files = files
        self.system = system
        value = try Theme.parse(JSON.parse(Data(contentsOf: files.defaultTheme)), palette: Palette(nil, system: system))
    }

    func loadPalette() {
        do {
            palette = try files.paletteFile()
            for problem in palette?.ignored ?? [] {
                log("palette.toml \(problem); ignored")
            }
        } catch {
            log("palette.toml: \(error); using the built-in palette")
            palette = nil
        }
    }

    func follow(_ mode: Palette.Mode) -> Bool {
        guard mode != system else { return false }
        system = mode
        return true
    }

    func reload() throws -> Bool {
        try apply(payload)
    }

    func apply(_ payload: JSON?) throws -> Bool {
        let next = try files.theme(palette: palette, system: system, override: payload)
        self.payload = payload
        guard next != value else { return false }
        value = next
        return true
    }
}
