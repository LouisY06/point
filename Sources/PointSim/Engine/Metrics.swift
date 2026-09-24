import Foundation

/// Derived numbers the report shows and scenarios can regress against. Everything here is a pure
/// function of the frames and events, so metrics never need their own hooks in the engine.
public enum Metrics {
    public static func compute(frames: [Trace.Frame], events: [Trace.Event],
                               rejectedCommands: Int, rerouteCount: Int) -> Trace.Metrics {
        let confirms = events.filter { $0.kind == "haptic.confirm" }
        let errors = confirms.compactMap { Double($0.detail["errorDegrees"] ?? "") }.map(abs)
        let conservative = confirms.compactMap { Double($0.detail["conservativeDegrees"] ?? "") }
        let navStart = events.first { $0.kind == "nav.start" }?.t
        let firstConfirm = confirms.first?.t
        return Trace.Metrics(
            timeToFirstConfirmSeconds: firstConfirm,
            confirmPulses: confirms.count,
            stopCommands: events.filter { $0.kind == "haptic.stop" }.count,
            // A pulse outside the engine's own hysteresis window would be a guidance bug.
            falseConfirms: conservative.filter { $0 > 25 }.count,
            meanAbsErrorWhileConfirming: errors.isEmpty ? nil : errors.reduce(0, +) / Double(errors.count),
            maxConservativeErrorAtConfirm: conservative.max(),
            // How long the user hunted for the direction after guidance became available.
            sweepSecondsToFirstConfirm: navStart.flatMap { start in firstConfirm.map { $0 - start } },
            arrivalSeconds: events.first { $0.kind == "nav.arrived" }?.t,
            beaconArrivals: events.filter { $0.kind == "beacon.arrival" || $0.kind == "nav.arrived" }.count,
            rerouteCount: rerouteCount,
            rejectedCommands: rejectedCommands,
            frames: frames.count)
    }
}
