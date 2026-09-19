import CryptoKit
import Foundation

/// Loads scenarios from disk, runs them and writes artifacts. Tests and the CLI share this path so
/// a failure seen in CI can be reproduced with the same trace locally.
@MainActor public enum SimRunner {
    public struct Artifacts {
        public let trace: Trace
        public let traceURL: URL?
        public let reportURL: URL?
    }

    public static func loadScenario(at url: URL) throws -> (Scenario, String) {
        let data = try Data(contentsOf: url)
        let scenario = try JSONDecoder().decode(Scenario.self, from: data).validated()
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (scenario, String(hash.prefix(12)))
    }

    public static func scenarioURLs(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    @discardableResult
    public static func run(scenarioURL: URL, outputDirectory: URL?, fixturesDirectory: URL?,
                           seedOverride: UInt64? = nil) async throws -> Artifacts {
        let (loaded, hash) = try loadScenario(at: scenarioURL)
        var scenario = loaded
        if let seedOverride { scenario.seed = seedOverride }
        let engine = SimulationEngine(scenario: scenario, fixturesDirectory: fixturesDirectory,
                                      scenarioHash: hash)
        let trace = try await engine.run()
        guard let outputDirectory else { return Artifacts(trace: trace, traceURL: nil, reportURL: nil) }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let traceURL = outputDirectory.appendingPathComponent("\(scenario.id).trace.json")
        let reportURL = outputDirectory.appendingPathComponent("\(scenario.id).md")
        try trace.encoded().write(to: traceURL)
        try Report.markdown(for: trace).data(using: .utf8)?.write(to: reportURL)
        return Artifacts(trace: trace, traceURL: traceURL, reportURL: reportURL)
    }

    /// Default locations when the harness runs from a checkout: `Scenarios/`, `Fixtures/routes/`
    /// and the git-ignored `.sim-out/`.
    public enum Paths {
        public static func repositoryRoot(from file: String = #filePath) -> URL {
            URL(fileURLWithPath: file) // Sources/PointSim/Runner.swift
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        }

        public static var scenarios: URL { repositoryRoot().appendingPathComponent("Scenarios") }
        public static var fixtures: URL { repositoryRoot().appendingPathComponent("Fixtures/routes") }
        public static var output: URL { repositoryRoot().appendingPathComponent(".sim-out") }
    }
}
