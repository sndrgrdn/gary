import AppKit
import GaryCore

extension Capability {
    static let colorpicker = Capability(
        name: "colorpicker",
        summary: """
        Pick a colour from anywhere on screen with the macOS magnifier. It resolves with the colour the user clicks as `#rrggbb` in sRGB, \
        or null after escape. It needs no permission.
        """,
        types: """
        declare namespace Gary {
          interface Host { colorpicker: { pick(): Promise<string | null> } }
        }
        """,
        example: """
        export default {
          async onAction() {
            host.hide();
            const color = await host.colorpicker.pick();
            if (color) host.clipboard.writeText(color);
          },
          render() {
            return { type: "text", text: "Pick a colour", action: "pick" };
          },
        } satisfies Gary.Menu;
        """,
        install: { host, plugin in
            plugin.installAPI(host, "colorpicker", ["pick"]) { call in
                guard call.method == "pick" else { throw call.unknownMethod }
                return .pending { finish in
                    DispatchQueue.main.async {
                        NSColorSampler().show { color in finish(.success(color.map { .string(sRGBHex($0)) } ?? .null)) }
                    }
                }
            }
        },
    )
}

func sRGBHex(_ color: NSColor) -> String {
    let srgb = color.usingColorSpace(.sRGB) ?? .black
    let clamp = { (value: CGFloat) in min(1, max(0, Double(value))) }
    return RGBA(red: clamp(srgb.redComponent), green: clamp(srgb.greenComponent), blue: clamp(srgb.blueComponent)).hex
}
