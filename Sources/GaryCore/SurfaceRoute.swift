public enum SurfaceRoute: Equatable, Sendable {
    case show(Int)
    case learn(Int)
    case unknown

    public static func choose(_ name: String, declared: [[String]?]) -> SurfaceRoute {
        for (index, names) in declared.enumerated() {
            if names?.contains(name) == true {
                return .show(index)
            }
            if names == nil {
                return declared[(index + 1)...].contains { $0?.contains(name) != false } ? .learn(index) : .show(index)
            }
        }
        return .unknown
    }
}
