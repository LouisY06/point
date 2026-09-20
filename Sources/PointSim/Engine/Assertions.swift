import Foundation

/// Declarative expectations, so a new case usually means a new JSON scenario rather than new Swift.
public enum Assertions {
    public static func evaluate(_ expectations: [Expectation], frames: [Trace.Frame],
                                events: [Trace.Event], metrics: Trace.Metrics) -> [Trace.Result] {
        expectations.map { evaluate($0, frames: frames, events: events, metrics: metrics) }
    }

    private static func evaluate(_ expectation: Expectation, frames: [Trace.Frame],
                                 events: [Trace.Event], metrics: Trace.Metrics) -> Trace.Result {
        func result(_ verdict: Trace.Result.Verdict, _ detail: String) -> Trace.Result {
            Trace.Result(expectation: expectation.summary, verdict: verdict, detail: detail)
        }

        switch expectation {
        case .endState(let expected):
            let actual = frames.last?.state ?? "none"
            return result(actual == expected ? .passed : .failed, "final state \(actual)")

        case .arrival(let beacon, let beforeSeconds):
            let match = beacon == "final"
                ? events.first { $0.kind == "nav.arrived" }
                : events.first { $0.kind == "beacon.arrival" && $0.detail["index"] == beacon }
            guard let match else { return result(.failed, "no arrival recorded for \(beacon)") }
            return result(match.t <= beforeSeconds ? .passed : .failed,
                          String(format: "arrived at %.1f s", match.t))

        case .confirmPulses(let min, let max):
            let count = metrics.confirmPulses
            let low = min.map { count >= $0 } ?? true
            let high = max.map { count <= $0 } ?? true
            return result(low && high ? .passed : .failed, "\(count) confirm pulses")

        case .noConfirmBefore(let alignedWithinDegrees):
            let bad = events.filter {
                $0.kind == "haptic.confirm"
                    && (Double($0.detail["conservativeDegrees"] ?? "") ?? .infinity) > alignedWithinDegrees
            }
            guard let first = bad.first else {
                return result(.passed, "no pulse outside \(Int(alignedWithinDegrees))°")
            }
            return result(.failed, String(format: "pulse at %.1f s with %@° conservative error",
                                          first.t, first.detail["conservativeDegrees"] ?? "?"))

        case .eventOrder(let kinds):
            var remaining = kinds[...]
            for event in events where event.kind == remaining.first {
                remaining = remaining.dropFirst()
                if remaining.isEmpty { break }
            }
            return result(remaining.isEmpty ? .passed : .failed,
                          remaining.isEmpty ? "order satisfied" : "missing \(remaining.joined(separator: ", "))")

        case .silentAfter(let kind):
            guard let marker = events.first(where: { $0.kind == kind }) else {
                return result(.failed, "\(kind) never happened")
            }
            let noisy = events.filter { $0.kind == "haptic.confirm" && $0.t > marker.t }
            return result(noisy.isEmpty ? .passed : .failed,
                          noisy.isEmpty ? "silent after \(kind)"
                                        : "\(noisy.count) pulses after \(kind)")

        case .silentBetween(let from, let to):
            guard let start = events.first(where: { $0.kind == from }) else {
                return result(.failed, "\(from) never happened")
            }
            guard let end = events.first(where: { $0.kind == to && $0.t >= start.t }) else {
                return result(.failed, "\(to) never happened after \(from)")
            }
            let noisy = events.filter { $0.kind == "haptic.confirm" && $0.t > start.t && $0.t < end.t }
            return result(noisy.isEmpty ? .passed : .failed,
                          noisy.isEmpty ? String(format: "silent for %.1f s", end.t - start.t)
                                        : "\(noisy.count) pulses between \(from) and \(to)")

        case .neverIntent(let intent):
            guard intent.isImplemented else {
                return result(.passed, "\(intent.rawValue) is not part of the firmware contract yet")
            }
            let hits = events.filter { $0.detail["intent"] == intent.rawValue }
            return result(hits.isEmpty ? .passed : .failed, "\(hits.count) occurrences")

        case .requiresIntent(let intent):
            // Reserved intents report as untested rather than failing: the hardware contract in
            // docs/HARDWARE_INTERFACE.md does not define them yet.
            guard intent.isImplemented else {
                return result(.untested, "\(intent.rawValue) is reserved, no firmware opcode defined")
            }
            let hits = events.filter { $0.detail["intent"] == intent.rawValue }
            return result(hits.isEmpty ? .failed : .passed, "\(hits.count) occurrences")
        }
    }
}
