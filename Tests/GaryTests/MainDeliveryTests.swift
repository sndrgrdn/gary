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

    private func record(_ handled: @escaping @MainActor (String) -> Void, interval: Double = MainDelivery.frame) -> MainDelivery {
        MainDelivery(interval: interval) { _, event in
            switch event {
            case let .output(output, _): handled((output.trees[SurfaceAddress.main]?[display.id]??.content).map { "\($0)" } ?? "none")
            case let .failed(reason): handled("failed \(reason)")
            default: handled("other")
            }
        }
    }

    @Test func `outputs sent before the main thread runs collapse into the newest one and other events still arrive`() async throws {
        let harness = try Harness(widget(""))
        defer { harness.runtime.stop() }
        var handled: [String] = []
        let delivery = record { handled.append($0) }
        delivery.send(harness.runtime, output("1"))
        delivery.send(harness.runtime, .failed("first"))
        delivery.send(harness.runtime, output("2"))
        delivery.send(harness.runtime, output("3"))
        await drainMain()
        #expect(handled == [#"text("3")"#, "failed first"])
    }

    @Test func `an output within a frame of the last one waits for the next frame and only the newest is applied`() async throws {
        let harness = try Harness(widget(""))
        defer { harness.runtime.stop() }
        let (applied, arrive) = AsyncStream.makeStream(of: (text: String, at: DispatchTime).self)
        let delivery = record({ arrive.yield(($0, .now())) }, interval: 0.5)
        var arrivals = applied.makeAsyncIterator()
        delivery.send(harness.runtime, output("1"))
        let first = try #require(await arrivals.next())
        for text in ["2", "3", "4"] {
            delivery.send(harness.runtime, output(text))
        }
        let second = try #require(await arrivals.next())
        #expect([first.text, second.text] == [#"text("1")"#, #"text("4")"#])
        #expect(second.at.uptimeNanoseconds - first.at.uptimeNanoseconds >= 500_000_000)
    }
}
