import CoreLocation
import Foundation
import Testing
import PointSim

struct HarnessUnitTests {
    @Test func seededRandomIsStableAcrossInstances() {
        var a = SeededRandom(seed: 5)
        var b = SeededRandom(seed: 5)
        var c = SeededRandom(seed: 6)
        let first = (0..<8).map { _ in a.uniform() }
        #expect(first == (0..<8).map { _ in b.uniform() })
        #expect(first != (0..<8).map { _ in c.uniform() })
        #expect(first.allSatisfy { (0..<1).contains($0) })
    }

    @Test func geometryRoundTripsBearingAndOffset() {
        let origin = CLLocationCoordinate2D(latitude: 42.36207, longitude: -71.08636)
        for bearing in stride(from: 0.0, to: 360, by: 45) {
            let moved = SimGeometry.offset(from: origin, bearingDegrees: bearing, distanceMeters: 150)
            #expect(abs(SimGeometry.distanceMeters(origin, moved) - 150) < 1)
            #expect(abs(SimGeometry.bearingDegrees(from: origin, to: moved) - bearing) < 0.5)
        }
    }

    @Test func walkerStopsAtTheEndOfThePathAndHonoursPauses() throws {
        let json = """
        {"startAt": 0, "speedMps": 1, "pauses": [{"from": 2, "to": 4}],
         "gps": {"accuracyMeters": 5, "noiseMeters": 0, "updateHz": 1}}
        """
        let spec = try JSONDecoder().decode(WalkerSpec.self, from: Data(json.utf8))
        let origin = CLLocationCoordinate2D(latitude: 42.36207, longitude: -71.08636)
        let end = SimGeometry.offset(from: origin, bearingDegrees: 0, distanceMeters: 10)
        var walker = Walker(spec: spec, path: [origin, end])
        let clock = VirtualClock(tickHz: 10)
        var random = SeededRandom(seed: 1)
        for tick in 0...200 { walker.advance(to: Double(tick) / 10, tickInterval: 0.1) }
        #expect(walker.finished)
        #expect(SimGeometry.distanceMeters(walker.truth, end) < 0.5)
        // 20 s of walking at 1 m/s over a 10 m path, minus a 2 s pause, cannot overshoot.
        let fix = walker.fix(at: 20, clock: clock, random: &random)
        #expect(fix?.location.horizontalAccuracy == 5)
    }

    @Test func unknownExpectationKeysFailToDecodeInsteadOfSilentlyPassing() {
        let json = Data(#"[{"totallyUnknown": 1}]"#.utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode([Expectation].self, from: json) }
    }

    @Test func scenarioValidationRejectsIncompleteRoutes() {
        let json = Data(#"{"id": "x", "route": {"kind": "generated"}}"#.utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(Scenario.self, from: json).validated() }
    }

    @Test func reservedIntentsAreNotClaimedAsImplemented() {
        #expect(HapticIntent.confirmAlignment.isImplemented)
        #expect(HapticIntent.stop.isImplemented)
        for intent in HapticIntent.allCases where intent != .confirmAlignment && intent != .stop {
            #expect(!intent.isImplemented, "\(intent.rawValue) has no firmware opcode yet")
        }
    }
}
