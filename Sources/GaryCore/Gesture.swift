public extension Node {
    enum Gesture: String, CaseIterable, Sendable {
        case click = "action"
        case rightClick = "rightAction"
        case middleClick = "middleAction"
        case scroll = "scrollAction"
    }
}
