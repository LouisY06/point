import Foundation

/// Simulation time. Every production call receives an explicit `now:`, so the harness never sleeps
/// and a run is reproducible from (scenario, seed).
public struct VirtualClock {
    public let start: Date
    public let tickHz: Double

    public init(start: Date = Date(timeIntervalSince1970: 1_700_000_000), tickHz: Double) {
        self.start = start
        self.tickHz = max(1, tickHz)
    }

    public var tickInterval: TimeInterval { 1 / tickHz }

    public func date(atSecond second: TimeInterval) -> Date { start.addingTimeInterval(second) }

    public func second(of date: Date) -> TimeInterval { date.timeIntervalSince(start) }
}

/// SplitMix64. Small, dependency free and identical across platforms and Swift versions.
public struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    private var spareNormal: Double?

    public init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    public mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    public mutating func uniform() -> Double { Double(next() >> 11) * 0x1p-53 }

    /// Box–Muller, mean 0 and standard deviation 1.
    public mutating func normal() -> Double {
        if let spare = spareNormal { spareNormal = nil; return spare }
        let u1 = max(uniform(), 1e-12)
        let u2 = uniform()
        let magnitude = (-2 * log(u1)).squareRoot()
        spareNormal = magnitude * sin(2 * .pi * u2)
        return magnitude * cos(2 * .pi * u2)
    }
}
