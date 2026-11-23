import Foundation
import GaryCore

final class PluginSetup {
    struct Refresh {
        var response: Response
        var packagesChanged = false
        var resolved = false
        var settingsChanged: Set<PluginID> = []
    }

    private let files: ConfigFiles
    private(set) var config = ShellConfig.defaults
    private(set) var catalog = PluginCatalog()
    private(set) var resolution: ShellConfig.Resolution

    init(files: ConfigFiles) {
        self.files = files
        resolution = config.resolve(catalog)
    }

    var enabledManifests: [PluginManifest] {
        resolution.enabled.compactMap { catalog.plugins[$0]?.manifest }
    }

    func wanted(builtinBar: Bool) -> [SlotKey: PluginBundle] {
        var wanted: [SlotKey: PluginBundle] = [:]
        if builtinBar {
            for id in resolution.bar.values.joined() {
                wanted[SlotKey(id: id, kind: .barWidget)] = catalog.plugins[id]
            }
        }
        if let id = resolution.barPlugin {
            wanted[SlotKey(id: id, kind: .bar)] = catalog.plugins[id]
        }
        for bundle in resolution.enabled.compactMap({ catalog.plugins[$0] }) {
            for kind in bundle.manifest.kinds where kind.isSurface || kind == .service {
                wanted[SlotKey(id: bundle.manifest.id, kind: kind)] = bundle
            }
        }
        return wanted
    }

    func refresh(config reloadsConfig: Bool, catalog rescans: Bool) -> Refresh {
        let previous = config
        var refresh = Refresh(response: reloadsConfig ? loadConfig() : .ok("config unchanged"))
        refresh.packagesChanged = config.packages != previous.packages
        if rescans || refresh.packagesChanged {
            scan()
        }
        guard rescans || config != previous else { return refresh }
        resolve()
        refresh.resolved = true
        refresh.settingsChanged = Set(config.settings.keys).union(previous.settings.keys).filter { config.settings[$0] != previous.settings[$0] }
        return refresh
    }

    private func loadConfig() -> Response {
        do {
            guard let loaded = try files.config() else {
                config = .defaults
                return .ok("no shell.json; using defaults")
            }
            config = loaded
            for warning in config.warnings {
                log("\(warning); skipped")
            }
            return .ok("config loaded")
        } catch {
            log("\(error); keeping the current config")
            return .failure("\(error)")
        }
    }

    private func scan() {
        catalog = files.catalog(config.packages)
        for problem in catalog.problems {
            log("plugin \(problem.directory.path): \(problem.reason)")
        }
    }

    private func resolve() {
        resolution = config.resolve(catalog)
        for warning in resolution.warnings {
            log("shell.json: \(warning)")
        }
    }
}
