import Foundation
@testable import gary
import GaryCore
import Testing

@MainActor @Suite(.serialized)
struct MainDeliveryTests {
    private func output(_ text: String, refreshRate: Int = 120) -> RuntimeEvent {
        .output(RuntimeOutput(trees: [SurfaceAddress.main: [display.id: Node(.text(text))]], refreshRate: refreshRate), Trace("test"))
    }

    private func drainMain() async {
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
    }

    private func record(_ handled: @escaping @MainActor (String) -> Void) -> MainDelivery {
        MainDelivery { _, event in
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

    @Test func `an output within a frame of its display's refresh rate waits for the next frame and only the newest is applied`() async throws {
        let harness = try Harness(widget(""))
        defer { harness.runtime.stop() }
        let (applied, arrive) = AsyncStream.makeStream(of: (text: String, at: DispatchTime).self)
        let delivery = record { arrive.yield(($0, .now())) }
        var arrivals = applied.makeAsyncIterator()
        delivery.send(harness.runtime, output("1", refreshRate: 2))
        let first = try #require(await arrivals.next())
        for text in ["2", "3", "4"] {
            delivery.send(harness.runtime, output(text, refreshRate: 2))
        }
        let second = try #require(await arrivals.next())
        #expect([first.text, second.text] == [#"text("1")"#, #"text("4")"#])
        #expect(second.at.uptimeNanoseconds - first.at.uptimeNanoseconds >= 500_000_000)
    }

    @Test func `applies past the main thread's budget for a frame wait for the next frame, oldest first`() async {
        var time = ProcessInfo.processInfo.systemUptime + 1
        ApplyBudget.clock = { time }
        defer { ApplyBudget.clock = { ProcessInfo.processInfo.systemUptime } }
        let (applied, arrive) = AsyncStream.makeStream(of: Int.self)
        var order: [Int] = []
        for index in 0..<4 {
            ApplyBudget.run(interval: 1 / 120.0) {
                time += ApplyBudget.perFrame * 0.75
                order.append(index)
                arrive.yield(index)
            }
        }
        #expect(order == [0, 1])
        var arrivals = applied.makeAsyncIterator()
        for _ in 0..<4 {
            _ = await arrivals.next()
        }
        #expect(order == [0, 1, 2, 3])
    }
}
