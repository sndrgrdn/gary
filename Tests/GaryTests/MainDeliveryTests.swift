import Foundation
@testable import gary
import GaryCore
import Testing

@MainActor
struct MainDeliveryTests {
    private func output(_ text: String) -> RuntimeEvent {
        .output(RuntimeOutput(trees: [SurfaceAddress.main: [display.id: Node(.text(text))]]), Trace("test"))
    }

    private func drainMain() async {
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
    }

    @Test func `an output queued behind a newer one is skipped and other events keep their order`() async throws {
        let harness = try Harness(widget(""))
        defer { harness.runtime.stop() }
        var handled: [String] = []
        let delivery = MainDelivery { _, event in
            switch event {
            case let .output(output, _): handled.append(output.trees[SurfaceAddress.main]?[display.id].map { "\($0.content)" } ?? "none")
            case let .failed(reason): handled.append("failed \(reason)")
            default: handled.append("other")
            }
        }
        delivery.send(harness.runtime, output("1"))
        delivery.send(harness.runtime, .failed("first"))
        delivery.send(harness.runtime, output("2"))
        delivery.send(harness.runtime, output("3"))
        await drainMain()
        #expect(handled == ["failed first", #"text("3")"#])
        delivery.send(harness.runtime, output("4"))
        await drainMain()
        #expect(handled.last == #"text("4")"#)
    }
}
