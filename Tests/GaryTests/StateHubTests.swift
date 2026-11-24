import Foundation
@testable import gary
import GaryCore
import Testing

private final class Feed: TopicFeed {}

struct StateHubTests {
    @Test func `every subscribed topic starts in order on the main run loop`() async {
        let names = ["first", "second", "third"]
        let (starts, started) = AsyncStream.makeStream(of: String.self)
        let hub = StateHub(sources: Dictionary(uniqueKeysWithValues: names.map { name in
            (Topic.capability(name), { @MainActor @Sendable _ in
                started.yield(name)
                return Feed()
            } as TopicSource)
        }))
        let listener = Listener()
        _ = hub.subscribe(listener, to: names.map(Topic.capability))
        var order: [String] = []
        for await name in starts.prefix(names.count) {
            order.append(name)
        }
        #expect(order == names)
    }
}
