import Foundation
@testable import gary
import GaryCore
import Testing

struct PluginModuleTests {
    @Test func `a module without a default export fails the load`() async throws {
        let harness = try Harness("export const render = function () {};", kind: .service, shown: [])
        #expect(try await harness.failure() == "Error: the entry file has no default export")
    }

    @Test func `relative imports load once per context and type only imports vanish`() async throws {
        let harness = try Harness(widget("render: function () { return { type: \"text\", text: label(count) + \" \" + loads() }; },", setup: """
        import { label } from "./lib/label";
        import { loads } from "./lib";
        """), files: [
            "lib/label.ts": """
            import type { Shape } from "./shape";
            import { loads } from "./index";
            export function label(n: number): string { return "n=" + n + "," + loads(); }
            """,
            "lib/index.js": "var count = 0; count += 1; export function loads() { return count; }",
        ])
        #expect(try await harness.text() == "n=0,1 1")
        harness.runtime.stop()
    }

    @Test func `an import Gary cannot resolve fails the load and names the specifier`() async throws {
        let cases = [
            "lodash": "cannot import \"lodash\" from main.js: Gary resolves only relative paths inside the plugin folder, such as \"./parse\"",
            "./missing": """
            cannot import "./missing" from main.js: no file missing.ts, missing.tsx, missing.js, missing/index.ts, missing/index.tsx, missing/index.js
            """,
            "../outside": "cannot import \"../outside\" from main.js: the path leaves the plugin folder",
        ]
        for (specifier, reason) in cases {
            let harness = try Harness(widget(setup: "import \"\(specifier)\";"), shown: [])
            #expect(try await harness.failure() == reason)
        }
    }
}
