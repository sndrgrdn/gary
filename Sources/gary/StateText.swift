import GaryCore

struct StateText {
    private var topics: [String: String] = [:]
    private var shared: [String: String]
    let settings: String

    init(settings: JSON, theme: JSON) {
        self.settings = settings.text
        shared = ["settings": self.settings, "theme": theme.text]
    }

    @discardableResult
    mutating func set(_ topic: Topic, _ value: JSON) -> String {
        let text = value.text
        topics[topic.description] = text
        return text
    }

    mutating func setTheme(_ theme: JSON) {
        shared["theme"] = theme.text
    }

    func text(display: DisplayInfo?, surface: String?) -> String {
        var fields = topics.merging(shared) { $1 }
        fields["display"] = display?.json.text
        fields["surface"] = surface.map { JSON.string($0).text }
        return "{" + fields.sorted { $0.key < $1.key }.map { JSON.string($0.key).text + ":" + $0.value }.joined(separator: ",") + "}"
    }
}
