import Foundation
import GaryCore
import Vision

nonisolated extension Capability {
    static let vision = Capability(
        name: "vision",
        summary: """
        Read the text, or the QR codes and barcodes, in an image file or an area of the screen with the Vision framework. An area is a `ScreenArea` from the `screen` \
        capability, such as the one `host.screen.select()` resolves with, and needs Screen Recording; an image file needs no permission. \
        The first read after Gary is installed or moved takes about 30 seconds while macOS prepares the text model.
        """,
        types: """
        declare namespace Gary {
          interface Host { vision: VisionApi }
          interface VisionApi {
            readText(image: string | ScreenArea): Promise<string>;
            readCodes(image: string | ScreenArea): Promise<{ symbology: string; payload: string | null }[]>;
          }
        }
        """,
        example: """
        export default {
          async onAction() {
            host.hide();
            const area = await host.screen.select();
            if (!area) return;
            const text = await host.vision.readText(area);
            host.clipboard.writeText(text);
          },
          render() {
            return { type: "text", text: "Copy text from the screen", action: "read" };
          },
        } satisfies Gary.Menu;
        """,
        permissions: [.screenRecording],
        install: { host, plugin in
            let folder = plugin.bundle.directory.path
            plugin.installAPI(host, "vision", VisionRequest.methods) { call in
                switch try VisionRequest.parse(call, home: home, folder: folder) {
                case let .readText(source): .task { try await .string(readText(source)) }
                case let .readCodes(source): .task { try await .array(readCodes(source)) }
                }
            }
        },
    )
}

private nonisolated func readText(_ source: ImageSource) async throws -> String {
    var request = RecognizeTextRequest()
    request.automaticallyDetectsLanguage = true
    let observations = try await perform(request, on: source)
    return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
}

private nonisolated func readCodes(_ source: ImageSource) async throws -> [JSON] {
    let request = DetectBarcodesRequest()
    let observations = try await perform(request, on: source)
    return observations.map { code in
        .object(["symbology": .string(String(describing: code.symbology)), "payload": code.payloadString.map(JSON.string) ?? .null])
    }
}

private nonisolated func perform<Request: ImageProcessingRequest>(_ request: Request, on source: ImageSource) async throws -> Request.Result {
    switch source {
    case let .file(path): try await request.perform(on: imageURL(path))
    case let .screen(area): try await request.perform(on: captureImage(area))
    }
}

private nonisolated func imageURL(_ path: String) throws -> URL {
    guard FileManager.default.isReadableFile(atPath: path) else { throw HostFailure("\(path) is not a readable image") }
    return URL(fileURLWithPath: path)
}
