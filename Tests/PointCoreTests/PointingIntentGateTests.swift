import CoreLocation
import Foundation
import Testing
@testable import PointCore

private let epoch = Date(timeIntervalSince1970: 20000)
private func t(_ seconds: Double) -> Date { epoch.addingTimeInterval(seconds) }

struct PointingIntentGateTests {
    @Test func walkingArmsOnlyAfterRisingFromHanging() {
        var gate = PointingIntentGate(mode: .walking)
        for i in 0..<5 { gate.update(elevationDegrees: 0, now: t(Double(i) * 0.1)) }
        #expect(!gate.isArmed(now: t(0.4))) // Level from the start is a handlebar, not intent.
        gate.update(elevationDegrees: -80, now: t(0.5))
        gate.update(elevationDegrees: -40, now: t(0.6))
        #expect(!gate.isArmed(now: t(0.6)))
        gate.update(elevationDegrees: 0, now: t(0.7))
        #expect(gate.isArmed(now: t(0.7)))
        // A short dip below the band keeps the window; a longer one needs a new raise.
        gate.update(elevationDegrees: -35, now: t(0.8))
        gate.update(elevationDegrees: -35, now: t(1.1))
        #expect(gate.isArmed(now: t(1.1)))
        gate.update(elevationDegrees: -35, now: t(1.3))
        #expect(!gate.isArmed(now: t(1.3)))
        gate.update(elevationDegrees: 0, now: t(1.4))
        #expect(!gate.isArmed(now: t(1.4)))
        gate.update(elevationDegrees: -60, now: t(1.5))
        gate.update(elevationDegrees: 10, now: t(1.6))
        #expect(gate.isArmed(now: t(1.6)))
        #expect(!gate.isArmed(now: t(2.2))) // No fresh sample.
    }

    @Test func hoveringAndArmSwingDoNotArmWalking() {
        var hover = PointingIntentGate()
        hover.update(elevationDegrees: -80, now: t(0))
        var seconds = 0.1
        while seconds < 1.35 { hover.update(elevationDegrees: -38, now: t(seconds)); seconds += 0.1 }
        hover.update(elevationDegrees: 0, now: t(1.4))
        #expect(!hover.isArmed(now: t(1.4))) // The band was entered more than a second after hanging.
        var swing = PointingIntentGate()
        for (i, elevation) in [-70.0, -55, -40, -50, -70, -55, -40].enumerated() {
            swing.update(elevationDegrees: elevation, now: t(Double(i) * 0.1))
        }
        #expect(!swing.isArmed(now: t(0.6)))
    }

    @Test func cyclingNeedsAHeldLiftThenLevelAndClosesByItself() {
        var gate = PointingIntentGate(mode: .cycling)
        for i in 0..<10 { gate.update(elevationDegrees: 5, now: t(Double(i) * 0.1)) }
        #expect(!gate.isArmed(now: t(0.9)))
        gate.update(elevationDegrees: 50, now: t(1.0))
        gate.update(elevationDegrees: 5, now: t(1.1))
        #expect(!gate.isArmed(now: t(1.1))) // Lift shorter than the hold.
        gate.update(elevationDegrees: 50, now: t(1.2))
        gate.update(elevationDegrees: 55, now: t(1.3))
        gate.update(elevationDegrees: 50, now: t(1.5))
        #expect(!gate.isArmed(now: t(1.5))) // Still lifted, not level.
        gate.update(elevationDegrees: 5, now: t(1.6))
        #expect(gate.isArmed(now: t(1.6)))
        var seconds = 1.7
        while seconds < 5.55 { gate.update(elevationDegrees: 5, now: t(seconds)); seconds += 0.1 }
        #expect(gate.isArmed(now: t(5.5)))
        gate.update(elevationDegrees: 5, now: t(5.7))
        #expect(!gate.isArmed(now: t(5.7)))
        gate.update(elevationDegrees: 5, now: t(5.8))
        #expect(!gate.isArmed(now: t(5.8))) // A hand resting on the bar never re-arms.
        // The lift must be followed by level within the allowance.
        gate.update(elevationDegrees: 60, now: t(5.9)); gate.update(elevationDegrees: 60, now: t(6.2))
        seconds = 6.3
        while seconds < 7.85 { gate.update(elevationDegrees: 35, now: t(seconds)); seconds += 0.1 }
        gate.update(elevationDegrees: 5, now: t(7.9))
        #expect(!gate.isArmed(now: t(7.9)))
    }

    @Test func gapsInvalidSamplesAndModeChangesDiscardTheGesture() {
        var gate = PointingIntentGate()
        gate.update(elevationDegrees: -80, now: t(0))
        gate.update(elevationDegrees: 0, now: t(0.7))
        #expect(!gate.isArmed(now: t(0.7))) // The gap discarded the hanging evidence.
        gate.update(elevationDegrees: -80, now: t(0.8))
        gate.update(elevationDegrees: 0, now: t(0.9))
        #expect(gate.isArmed(now: t(0.9)))
        gate.update(elevationDegrees: .nan, now: t(0.95))
        #expect(gate.isArmed(now: t(0.95)))
        gate.setMode(.cycling)
        #expect(!gate.isArmed(now: t(0.95)))
        gate.setMode(.cycling)
        gate.update(elevationDegrees: -80, now: t(1.0))
        gate.update(elevationDegrees: 0, now: t(1.1))
        #expect(!gate.isArmed(now: t(1.1))) // The walking raise means nothing on a bike.
        gate.update(elevationDegrees: 0, now: t(0.5))
        #expect(!gate.isArmed(now: t(0.5)))
    }

    @Test func elevationFollowsThePointingAxis() {
        #expect(GloveQuaternion.elevationDegrees(SIMD3(0, 1, 0)) == 0)
        #expect(abs(GloveQuaternion.elevationDegrees(SIMD3(0, 0.70710678, 0.70710678))! - 45) < 0.001)
        #expect(GloveQuaternion.elevationDegrees(SIMD3(0, 0, -1)) == -90)
        #expect(GloveQuaternion.elevationDegrees(SIMD3(0, 0.2, 0)) == nil)
    }
}

@MainActor struct TravelModeOverrideTests {
    private func fix(speed: Double, at seconds: Double) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: 42.36, longitude: -71.06), altitude: 0,
                   horizontalAccuracy: 5, verticalAccuracy: 5, course: 0, speed: speed, timestamp: t(seconds))
    }

    @Test func sustainedSpeedOverridesOnlyAWalkingChoiceAndClearsOnStop() {
        let glove = SimulatedGlove()
        let controller = PointController(glove: glove)
        #expect(glove.travelMode == .walking && controller.effectiveTravelMode == .walking)
        for seconds in [0.0, 1, 2, 3, 4] { controller.updateLocation(fix(speed: 6, at: seconds), now: t(seconds)) }
        #expect(glove.travelMode == .walking) // One fix, or fewer than five seconds, never switches.
        controller.updateLocation(fix(speed: 6, at: 5), now: t(5))
        #expect(glove.travelMode == .cycling && controller.effectiveTravelMode == .cycling)
        controller.updateLocation(fix(speed: 3, at: 6), now: t(6)) // Between thresholds holds the state.
        controller.updateLocation(fix(speed: 1, at: 7), now: t(7))
        controller.updateLocation(fix(speed: -1, at: 9), now: t(9)) // Invalid speed is ignored.
        controller.updateLocation(fix(speed: 1, at: 11), now: t(11))
        #expect(glove.travelMode == .cycling)
        controller.updateLocation(fix(speed: 1, at: 12), now: t(12))
        #expect(glove.travelMode == .walking && controller.effectiveTravelMode == .walking)
        controller.travelMode = .cycling
        #expect(glove.travelMode == .cycling)
        controller.updateLocation(fix(speed: 0, at: 13), now: t(13))
        controller.updateLocation(fix(speed: 0, at: 20), now: t(20))
        #expect(glove.travelMode == .cycling) // An explicit cycling choice is never overridden.
        controller.travelMode = .walking
        #expect(glove.travelMode == .walking)
        controller.updateLocation(fix(speed: 5, at: 21), now: t(21))
        controller.updateLocation(fix(speed: 5, at: 26.5), now: t(26.5))
        #expect(glove.travelMode == .cycling)
        controller.stop()
        #expect(glove.travelMode == .walking)
        let other = SimulatedGlove()
        controller.updateLocation(fix(speed: 5, at: 30), now: t(30))
        controller.updateLocation(fix(speed: 5, at: 36), now: t(36))
        #expect(glove.travelMode == .cycling)
        controller.useTransport(other)
        #expect(other.travelMode == .walking && controller.effectiveTravelMode == .walking)
    }
}
