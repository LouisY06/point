import Foundation

/// Markdown report. Phase 2 adds the HTML replay console on top of the same trace.
public enum Report {
    public static func markdown(for trace: Trace) -> String {
        var lines: [String] = []
        lines.append("# \(trace.scenario.title)")
        lines.append("")
        lines.append("`\(trace.scenario.id)` · seed \(trace.scenario.seed) · \(trace.scenario.tickHz) Hz "
                     + "· scenario \(trace.scenario.hash) · **\(trace.passed ? "PASS" : "FAIL")**")
        lines.append("")
        lines.append("## Expectations")
        lines.append("")
        lines.append("| Expectation | Verdict | Detail |")
        lines.append("| --- | --- | --- |")
        for result in trace.results {
            lines.append("| \(result.expectation) | \(result.verdict.rawValue) | \(result.detail) |")
        }
        if trace.results.isEmpty { lines.append("| _none declared_ | | |") }
        lines.append("")
        lines.append("## Metrics")
        lines.append("")
        lines.append("| Metric | Value |")
        lines.append("| --- | --- |")
        let metrics = trace.metrics
        for (name, value) in [
            ("time to first confirm", seconds(metrics.timeToFirstConfirmSeconds)),
            ("sweep to first confirm", seconds(metrics.sweepSecondsToFirstConfirm)),
            ("confirm pulses", String(metrics.confirmPulses)),
            ("stop commands", String(metrics.stopCommands)),
            ("false confirms", String(metrics.falseConfirms)),
            ("mean |error| at confirm", degrees(metrics.meanAbsErrorWhileConfirming)),
            ("max conservative error at confirm", degrees(metrics.maxConservativeErrorAtConfirm)),
            ("beacon arrivals", String(metrics.beaconArrivals)),
            ("arrival", seconds(metrics.arrivalSeconds)),
            ("reroutes required", String(metrics.rerouteCount)),
            ("rejected commands", String(metrics.rejectedCommands)),
            ("frames", String(metrics.frames))
        ] {
            lines.append("| \(name) | \(value) |")
        }
        lines.append("")
        lines.append("## Timeline")
        lines.append("")
        for event in trace.events {
            let detail = event.detail.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            lines.append(String(format: "- `%7.2fs` **%@** %@", event.t, event.kind, detail))
        }
        if let untested = untestedSection(trace) { lines.append(contentsOf: untested) }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// Reserved haptic intents are reported, never silently treated as passing.
    private static func untestedSection(_ trace: Trace) -> [String]? {
        guard !trace.untested.isEmpty else { return nil }
        var lines = ["", "## Untested", ""]
        lines.append(contentsOf: trace.untested.map { "- \($0.expectation): \($0.detail)" })
        return lines
    }

    public static func summary(for traces: [Trace]) -> String {
        var lines = ["# Simulation run", "", "| Scenario | Verdict | Failures | Untested |", "| --- | --- | --- | --- |"]
        for trace in traces {
            lines.append("| \(trace.scenario.id) | \(trace.passed ? "PASS" : "FAIL") "
                         + "| \(trace.failures.count) | \(trace.untested.count) |")
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func seconds(_ value: Double?) -> String {
        value.map { String(format: "%.2f s", $0) } ?? "—"
    }

    private static func degrees(_ value: Double?) -> String {
        value.map { String(format: "%.1f°", $0) } ?? "—"
    }
}
