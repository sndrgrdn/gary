import Foundation
@testable import gary
import GaryCore
import Testing

struct PluginJSXTests {
    @Test func `jsx builds the same nodes as the object form`() async throws {
        let harness = try Harness("""
        import { jsx, objects } from "./view";
        export default {
          render() {
            var a = JSON.stringify(jsx(3)), b = JSON.stringify(objects(3));
            return { type: "text", text: a === b ? "same" : a + " != " + b };
          },
        };
        """, files: ["view.tsx": """
        function Badge(props: { label: string; children?: Gary.Child }) {
          return <row key="badge">{props.children}<text>{props.label}</text></row>;
        }

        export function jsx(count: number) {
          return (
            <row gap={8}>
              <text>{count} items</text>
              <text text={count} />
              <>{[1, 2].map((n) => <icon key={String(n)} symbol="star" />)}{false}{null}</>
              <Badge label="b"><spacer /></Badge>
            </row>
          );
        }

        export function objects(count: number) {
          return {
            type: "row",
            gap: 8,
            children: [
              { type: "text", text: count + " items" },
              { type: "text", text: count },
              { type: "icon", key: "1", symbol: "star" },
              { type: "icon", key: "2", symbol: "star" },
              { type: "row", key: "badge", children: [{ type: "spacer" }, { type: "text", text: "b" }] },
            ],
          };
        }
        """])
        #expect(try await harness.text() == "same")
        harness.runtime.stop()
    }
}
