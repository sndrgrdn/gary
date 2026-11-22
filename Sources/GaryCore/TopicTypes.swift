import Foundation

public extension PluginTypes {
    static let topicFile = "topic.ts"

    struct TopicType: Equatable, Sendable {
        public let topic: Topic
        public let type: String

        public init(_ topic: Topic, _ type: String) {
            self.topic = topic
            self.type = type
        }
    }

    static func topicImport(from directory: URL, to publisher: URL) -> String {
        let from = directory.standardizedFileURL.pathComponents
        let to = publisher.standardizedFileURL.appending(path: topicFile).deletingPathExtension().pathComponents
        let shared = zip(from, to).prefix { $0 == $1 }.count
        let path = (from.count == shared ? ["."] : Array(repeating: "..", count: from.count - shared)) + to.dropFirst(shared)
        return "import(\"\(path.joined(separator: "/"))\").Topic"
    }
}
