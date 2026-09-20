import Foundation
import Testing
@testable import PointCore

struct HapticSchedulerTests {
    private let epoch = Date(timeIntervalSince1970: 1_000)

    private func feedback(_ status: FeedbackStatus = .aligned, angle: Double? = 0) -> DirectionFeedback {
        DirectionFeedback(status: status, angularErrorDegrees: angle, distanceToBeaconMeters: 20)
    }

    @Test func alignedOutdoorGuidanceBuildsToDemoStrengthWithFrequentFinitePulses() {
        var scheduler = HapticScheduler()
        var pulses: [(time: Double, strength: UInt8)] = []
        for tick in 0...40 {
            let seconds = Double(tick) * 0.05
            if case .confirm(let duration, let strength) = scheduler.command(for: feedback(), now: epoch.addingTimeInterval(seconds)) {
                #expect(duration == 180)
                #expect((1...204).contains(strength))
                pulses.append((seconds, strength))
            }
        }
        #expect(pulses.count >= 8)
        #expect(pulses.count <= 11)
        for (previous, next) in zip(pulses, pulses.dropFirst()) {
            #expect(next.time - previous.time >= 0.199)
            #expect(next.time - previous.time <= 0.251)
            #expect(next.strength >= previous.strength)
        }
        #expect((pulses.last?.strength ?? 0) >= 200)
    }

    @Test func strengthEasesTowardTheEdgeWithoutSuppressingTheWiderPointingCone() {
        func settledStrength(at angle: Double) -> UInt8 {
            var scheduler = HapticScheduler()
            var result: UInt8 = 0
            for tick in 0...40 {
                if case .confirm(_, let strength) = scheduler.command(for: feedback(angle: angle), now: epoch.addingTimeInterval(Double(tick) * 0.05)) {
                    result = strength
                }
            }
            return result
        }
        #expect(settledStrength(at: 0) >= 200)
        #expect(settledStrength(at: 10) == settledStrength(at: 0))
        #expect(settledStrength(at: 25) > 0)
        #expect(settledStrength(at: 25) < settledStrength(at: 10))
        #expect(settledStrength(at: -25) == settledStrength(at: 25))
        #expect(settledStrength(at: 35) == 0)
    }

    @Test func losingAlignmentOrUsableDataStopsAndClearsThePulseRamp() {
        let losses: [DirectionFeedback] = [
            feedback(.inactive), feedback(.disconnected), feedback(.locationUnavailable),
            feedback(.headingUnavailable), feedback(.calibrationRequired), feedback(.rerouteRequired),
            feedback(.checking), feedback(.offDirection), feedback(angle: nil), feedback(angle: .nan)
        ]
        for loss in losses {
            var scheduler = HapticScheduler()
            let first = scheduler.command(for: feedback(), now: epoch)
            for tick in 1...20 {
                _ = scheduler.command(for: feedback(), now: epoch.addingTimeInterval(Double(tick) * 0.05))
            }
            #expect(scheduler.command(for: loss, now: epoch.addingTimeInterval(1.01)) == .stop)
            #expect(scheduler.command(for: loss, now: epoch.addingTimeInterval(1.02)) == nil)
            #expect(scheduler.command(for: feedback(), now: epoch.addingTimeInterval(1.03)) == first)
            scheduler.reset()
            #expect(scheduler.command(for: feedback(), now: epoch.addingTimeInterval(1.04)) == first)
        }
    }

    @Test func suspendedUpdatesCannotResumeAnOldStrongPulse() {
        var scheduler = HapticScheduler()
        let first = scheduler.command(for: feedback(), now: epoch)
        #expect(scheduler.command(for: feedback(), now: epoch.addingTimeInterval(0.5)) == .stop)
        #expect(scheduler.command(for: feedback(), now: epoch.addingTimeInterval(0.55)) == first)
    }
}
