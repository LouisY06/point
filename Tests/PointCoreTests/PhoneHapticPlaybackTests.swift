import Foundation
import Testing
@testable import PointCore

@MainActor struct PhoneHapticPlaybackTests {
    @Test func repeatedPointingSweepsAndCuesKeepPlayingWithoutRebuildingEngine() {
        let output = FakePhoneHaptics()
        let playback = PhoneHapticPlayback(output: output)
        playback.prepare(now: 0)
        var time = 0.0
        for _ in 0..<100 {
            // Point toward, turn away, then an arrival cue; repeat well beyond two uses.
            for tick in 0..<20 {
                playback.update(intensity: tick < 15 ? 0.6 : 0, isActive: true, now: time)
                time += 0.05
            }
            playback.prepare(now: time)
            playback.update(intensity: 0.8, isActive: true, now: time)
            #expect(output.playing)
            time += 0.5
        }
        #expect(output.preparations == 1)
        #expect(output.shutdowns == 0)
        #expect(output.bursts >= 300)
        #expect(playback.errorMessage == nil)
    }

    @Test func completedBurstMustRestartEvenWhenIntensityDoesNotChange() {
        let output = FakePhoneHaptics()
        let playback = PhoneHapticPlayback(output: output)
        playback.update(intensity: 0.8, isActive: true, now: 1)
        output.playing = false // Simulate the hardware's finite event expiring.
        playback.update(intensity: 0.8, isActive: true, now: 1.4)
        #expect(output.playing)
        #expect(output.bursts == 2)
        #expect(output.duration == 0.35)
    }

    @Test func engineInterruptionRecoversOnNextGuidanceUpdate() {
        let output = FakePhoneHaptics()
        let playback = PhoneHapticPlayback(output: output)
        playback.update(intensity: 0.8, isActive: true, now: 1)
        output.playing = false
        output.onInterruption?()
        #expect(playback.errorMessage != nil)
        playback.update(intensity: 0.6, isActive: true, now: 1.05)
        #expect(output.playing)
        #expect(output.preparations == 2)
        #expect(output.bursts == 2)
        #expect(playback.errorMessage == nil)
    }

    @Test func failedInitialStartAndFailedPlayerAreRetriedWithFreshOutput() {
        let output = FakePhoneHaptics()
        let playback = PhoneHapticPlayback(output: output)
        output.failPrepare = true
        playback.prepare(now: 1)
        #expect(playback.errorMessage != nil)
        playback.update(intensity: 0.8, isActive: true, now: 1.5)
        #expect(output.preparations == 1) // No retry storm at 20 Hz.
        output.failPrepare = false
        playback.update(intensity: 0.8, isActive: true, now: 2)
        #expect(output.playing)
        output.failChange = true
        playback.update(intensity: 0.7, isActive: true, now: 2.05)
        #expect(!output.playing)
        #expect(output.shutdowns == 2)
        output.failChange = false
        playback.update(intensity: 0.8, isActive: true, now: 3.1)
        #expect(output.playing)
        #expect(playback.errorMessage == nil)
    }

    @Test func shutdownIgnoresLateCallbacksAndInvalidInputSilences() {
        let output = FakePhoneHaptics()
        let playback = PhoneHapticPlayback(output: output)
        playback.update(intensity: 0.8, isActive: true, now: 1)
        let oldInterruption = output.onInterruption
        playback.shutdown()
        playback.update(intensity: 0.8, isActive: true, now: 2)
        oldInterruption?()
        #expect(playback.errorMessage == nil)
        #expect(output.playing)
        playback.update(intensity: 0.8, isActive: false, now: 2.05)
        #expect(!output.playing)
        playback.update(intensity: 0.8, isActive: true, now: 2.1)
        playback.update(intensity: .nan, isActive: true, now: 2.15)
        #expect(!output.playing)
    }
}

@MainActor private final class FakePhoneHaptics: PhoneHapticOutput {
    var onInterruption: (@MainActor () -> Void)?
    var preparations = 0
    var shutdowns = 0
    var bursts = 0
    var playing = false
    var duration: TimeInterval?
    var failPrepare = false
    var failChange = false
    enum Failure: Error { case interrupted }

    func prepare(onInterruption: @escaping @MainActor () -> Void) throws {
        preparations += 1
        if failPrepare { throw Failure.interrupted }
        self.onInterruption = onInterruption
    }
    func startBurst(intensity: Double, duration: TimeInterval) throws {
        bursts += 1
        playing = intensity > 0
        self.duration = duration
    }
    func changeIntensity(_ intensity: Double) throws {
        if failChange { throw Failure.interrupted }
    }
    func silence() { playing = false }
    func shutdown() { shutdowns += 1; playing = false }
}
