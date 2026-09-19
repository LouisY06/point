/// Bound marker work independently of route length. The full route and beacon list are retained.
public enum RouteMapWindow {
    public static func beaconIndices(count: Int, activeIndex: Int?) -> [Int] {
        guard count > 0 else { return [] }
        if let activeIndex, (0..<count).contains(activeIndex) {
            let nearby = max(0, activeIndex - 2)...min(count - 1, activeIndex + 8)
            return Array(Set(Array(nearby) + [0, count - 1])).sorted()
        }
        // Route overview samples at most 64 markers, including both ends.
        guard count > 64 else { return Array(0..<count) }
        return (0..<64).map { Int((Double($0) * Double(count - 1) / 63).rounded()) }
    }
}
