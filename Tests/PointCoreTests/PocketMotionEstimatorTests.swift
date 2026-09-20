import Foundation
import Testing
@testable import PointCore

struct PocketMotionEstimatorTests {
    @Test func estimatedArrivalRequiresDwellAndAnotherStepForTheNextBeacon() {
        var arrival = EstimatedBeaconArrival()
        let stationary = arrival.update(distance: 0.4, steps: 0, timestamp: 1)
        #expect(!stationary)
        let entering = arrival.update(distance: 0.6, steps: 2, timestamp: 2)
        #expect(!entering)
        let reached = arrival.update(distance: 0.5, steps: 2, timestamp: 2.7)
        #expect(reached)
        let duplicate = arrival.update(distance: 0.5, steps: 2, timestamp: 5)
        #expect(!duplicate)
        let nextEntry = arrival.update(distance: 0.5, steps: 3, timestamp: 6)
        #expect(!nextEntry)
        let next = arrival.update(distance: 0.5, steps: 3, timestamp: 6.7)
        #expect(next)
    }

    @Test func leavingRadiusOrPausingResetsArrivalDwell() {
        var arrival = EstimatedBeaconArrival()
        _ = arrival.update(distance: 0.5, steps: 1, timestamp: 1)
        _ = arrival.update(distance: 1.0, steps: 2, timestamp: 1.5)
        let reentry = arrival.update(distance: 0.5, steps: 3, timestamp: 2)
        #expect(!reentry)
        arrival.pause()
        let afterPause = arrival.update(distance: 0.5, steps: 3, timestamp: 3)
        #expect(!afterPause)
        _ = arrival.update(distance: .nan, steps: 3, timestamp: 3.1)
        let afterInvalid = arrival.update(distance: 0.5, steps: 3, timestamp: 4)
        #expect(!afterInvalid)
    }

    @Test func turnCuesUseBodyDirectionInTheSameRoomFrame() {
        #expect(EstimatedBeaconArrival.turnCue(targetX: 1, targetZ: 0, bodyHeading: 0) == "Turn right")
        #expect(EstimatedBeaconArrival.turnCue(targetX: -1, targetZ: 0, bodyHeading: 0) == "Turn left")
        #expect(EstimatedBeaconArrival.turnCue(targetX: 0, targetZ: 1, bodyHeading: 0) == "Turn around")
        #expect(EstimatedBeaconArrival.turnCue(targetX: 1, targetZ: 0, bodyHeading: 90) == "Continue forward")
    }

    @Test func stationaryNoiseDoesNotMoveAndTurningDoesNotCountSteps() {
        var model = PocketMotionEstimator(x: 2, z: 3, heading: 0, stepLength: 0.65, timestamp: 0)!
        for i in 1...500 {
            model.update(timestamp: Double(i) * 0.02, upwardAcceleration: sin(Double(i)) * 0.03,
                         upwardRotation: .pi / 20)
        }
        #expect(model.valid && model.steps == 0)
        #expect(model.x == 2 && model.z == 3)
        #expect(abs(model.heading + 90) < 0.001)
    }

    @Test func stepsAdvanceInRoomCoordinatesAndFollowTurns() {
        var model = PocketMotionEstimator(x: 0, z: 0, heading: 0, stepLength: 0.5, timestamp: 0)!
        var time = 0.0
        func sample(_ acceleration: Double, rotation: Double = 0, count: Int) {
            for _ in 0..<count {
                time += 0.02
                model.update(timestamp: time, upwardAcceleration: acceleration, upwardRotation: rotation)
            }
        }
        func step() { sample(0.25, count: 10); sample(-0.25, count: 10); sample(0, count: 10) }
        step(); step()
        #expect(model.steps == 2)
        #expect(abs(model.z + 1) < 0.001 && abs(model.x) < 0.001)
        sample(0, rotation: -.pi / 2, count: 50) // Clockwise 90 degrees, now +X.
        step(); step()
        #expect(model.steps == 4)
        #expect(abs(model.z + 1) < 0.001 && abs(model.x - 1) < 0.001)
        #expect(model.travelled == 2)
    }

    @Test func missingOrInvalidMotionInvalidatesPosition() {
        var model = PocketMotionEstimator(x: 0, z: 0, heading: 0, stepLength: 0.65, timestamp: 0)!
        model.update(timestamp: 1, upwardAcceleration: 0, upwardRotation: 0)
        #expect(!model.valid)
        model.update(timestamp: 1.02, upwardAcceleration: 0.3, upwardRotation: 0)
        #expect(!model.valid && model.steps == 0)
        var corrupt = PocketMotionEstimator(x: 0, z: 0, heading: 0, stepLength: 0.65, timestamp: 0)!
        corrupt.update(timestamp: 0.02, upwardAcceleration: .nan, upwardRotation: 0)
        #expect(!corrupt.valid)
        #expect(PocketMotionEstimator(x: .nan, z: 0, heading: 0, stepLength: 0.65, timestamp: 0) == nil)
        #expect(PocketMotionEstimator(x: 0, z: 0, heading: 0, stepLength: 0, timestamp: 0) == nil)
    }

    @Test func duplicateSamplesAndConstantBiasDoNotAddDistance() {
        var model = PocketMotionEstimator(x: 0, z: 0, heading: 180, stepLength: 0.65, timestamp: 0)!
        for i in 1...500 {
            let time = Double(i) * 0.02
            model.update(timestamp: time, upwardAcceleration: 0.15, upwardRotation: 0)
            model.update(timestamp: time, upwardAcceleration: -0.2, upwardRotation: 0)
        }
        #expect(model.valid && model.steps == 0 && model.travelled == 0)
    }
}
