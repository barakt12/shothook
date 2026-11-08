/// Most-recently-used list of harness bundle IDs; decides where a shot goes.
public struct MRUList: Sendable {
    public private(set) var items: [String] = []

    public init() {}

    public mutating func touch(_ id: String) {
        items.removeAll { $0 == id }
        items.insert(id, at: 0)
    }

    /// The most recently used harness that is still running; otherwise the first
    /// running one in config order; otherwise nil (shot stays on the clipboard).
    public func resolve(running: Set<String>, fallbackOrder: [String]) -> String? {
        items.first(where: running.contains) ?? fallbackOrder.first(where: running.contains)
    }
}
