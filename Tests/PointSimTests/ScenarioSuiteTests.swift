import Foundation
import Testing
import PointSim

/// Every file in `Scenarios/` is an integration test: adding a case means adding JSON, not Swift.
@MainActor struct ScenarioSuiteTests {
    static let scenarioURLs = (try? SimRunner.scenarioURLs(in: SimRunner.Paths.scenarios)) ?? []

    @Test(arguments: scenarioURLs)
    func scenarioMeetsItsExpectations(url: URL) async throws {
        let artifacts = try await SimRunner.run(scenarioURL: url,
                                                outputDirectory: SimRunner.Paths.output,
                                                fixturesDirectory: SimRunner.Paths.fixtures)
        let trace = artifacts.trace
        #expect(!trace.results.isEmpty, "\(trace.scenario.id) declares no expectations")
        for failure in trace.failures {
            Issue.record("\(trace.scenario.id): \(failure.expectation) — \(failure.detail)")
        }
        #expect(trace.failures.isEmpty)
    }

    @Test func runsAreReproducibleFromScenarioAndSeed() async throws {
        let url = SimRunner.Paths.scenarios.appendingPathComponent("straight-leg-alignment.json")
        let first = try await SimRunner.run(scenarioURL: url, outputDirectory: nil,
                                            fixturesDirectory: nil).trace
        let second = try await SimRunner.run(scenarioURL: url, outputDirectory: nil,
                                             fixturesDirectory: nil).trace
        #expect(first.frames.count == second.frames.count)
        #expect(first.metrics.confirmPulses == second.metrics.confirmPulses)
        #expect(zip(first.frames, second.frames).allSatisfy { $0.heading == $1.heading && $0.lat == $1.lat })
    }

    @Test func differentSeedsChangeSensorNoiseButNotTheVerdict() async throws {
        let url = SimRunner.Paths.scenarios.appendingPathComponent("straight-leg-alignment.json")
        let base = try await SimRunner.run(scenarioURL: url, outputDirectory: nil,
                                           fixturesDirectory: nil).trace
        let reseeded = try await SimRunner.run(scenarioURL: url, outputDirectory: nil,
                                               fixturesDirectory: nil, seedOverride: 99).trace
        #expect(base.passed && reseeded.passed)
        #expect(base.frames.map(\.heading) != reseeded.frames.map(\.heading))
    }

    @Test func reservedHapticIntentsReportAsUntestedRatherThanPassing() async throws {
        let url = SimRunner.Paths.scenarios.appendingPathComponent("voice-to-arrival.json")
        let trace = try await SimRunner.run(scenarioURL: url, outputDirectory: nil,
                                            fixturesDirectory: nil).trace
        #expect(trace.untested.contains { $0.expectation.contains("arrived") })
        #expect(trace.passed) // Untested never counts as a failure, and never as a pass either.
    }
}
