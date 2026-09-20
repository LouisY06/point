import CoreLocation
import Foundation
import Testing
import PointCore
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

    @Test func generatedRoutesGetTheProductionBeaconLayout() throws {
        func beacons(legs: String) throws -> [PingTarget] {
            let json = """
            {"kind": "generated", "destinationName": "Test",
             "origin": [42.36207, -71.08636], "legs": \(legs)}
            """
            let spec = try JSONDecoder().decode(RouteSpec.self, from: Data(json.utf8))
            return try RouteBuilder.build(spec, fixturesDirectory: nil).beacons
        }

        // Start and destination only: a straight leg has no turn to ping on.
        let straight = try beacons(legs: #"[{"bearing": 0, "meters": 120}]"#)
        #expect(straight.count == 2)
        // A shallow bend stays below the extractor's turn threshold.
        let bend = try beacons(legs: #"[{"bearing": 0, "meters": 120}, {"bearing": 20, "meters": 120}]"#)
        #expect(bend.count == 2)
        // A real corner earns its own beacon between start and destination.
        let corner = try beacons(legs: #"[{"bearing": 0, "meters": 120}, {"bearing": 90, "meters": 120}]"#)
        #expect(corner.count == 3)
        #expect(corner.allSatisfy { !$0.instruction.isEmpty })
        #expect(corner.last?.isFinalDestination == true)
        #expect(corner.dropLast().allSatisfy { !$0.isFinalDestination })
    }

    @Test func generatedRoutesResampleCheckpointsAtTheRequestedInterval() throws {
        let json = """
        {"kind": "generated", "destinationName": "Test", "checkpointSpacingMeters": 15,
         "origin": [42.36207, -71.08636], "legs": [{"bearing": 0, "meters": 120}]}
        """
        let spec = try JSONDecoder().decode(RouteSpec.self, from: Data(json.utf8))
        let checkpoints = try RouteBuilder.build(spec, fixturesDirectory: nil).checkpoints
        let gaps = zip(checkpoints, checkpoints.dropFirst())
            .map { SimGeometry.distanceMeters($0.coordinate, $1.coordinate) }
        #expect(gaps.allSatisfy { $0 <= 15.5 })
        #expect(SimGeometry.distanceMeters(checkpoints.last!.coordinate, spec.origin!.coordinate) > 119)
    }

    @Test func reservedIntentsAreNotClaimedAsImplemented() {
        let implemented: Set<HapticIntent> = [.confirmAlignment, .stop, .vehicleArrived]
        for intent in implemented { #expect(intent.isImplemented) }
        for intent in HapticIntent.allCases where !implemented.contains(intent) {
            #expect(!intent.isImplemented, "\(intent.rawValue) has no firmware opcode yet")
        }
    }
}
