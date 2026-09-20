import Testing
@testable import PointCore

struct AudioSessionPolicyTests {
    @Test func aPromptEndingKeepsTheSessionWhileTheHapticEngineRuns() {
        var policy = AudioSessionPolicy()
        #expect(policy.acquire(.haptics) == .silentHold)
        #expect(policy.acquire(.speaking) == .speaking)
        // The end of a prompt used to deactivate the shared session, which stopped the
        // running engine and dropped the directional cue around the prompt.
        #expect(policy.release(.speaking) == .silentHold)
        #expect(policy.release(.haptics) == .inactive)
    }

    @Test func speechWithoutGuidanceStillReleasesTheSessionWhenItFinishes() {
        var policy = AudioSessionPolicy()
        #expect(policy.acquire(.speaking) == .speaking)
        #expect(policy.release(.speaking) == .inactive)
    }

    @Test func theMicrophoneOutranksAPromptAndAHapticHold() {
        var policy = AudioSessionPolicy()
        policy.acquire(.haptics)
        policy.acquire(.speaking)
        #expect(policy.acquire(.recording) == .recording)
        #expect(policy.release(.recording) == .speaking)
    }

    @Test func overlappingPromptsHoldTheSessionUntilTheLastOneEnds() {
        var policy = AudioSessionPolicy()
        policy.acquire(.speaking)
        #expect(policy.acquire(.speaking) == .speaking)
        #expect(policy.release(.speaking) == .speaking)
        #expect(policy.release(.speaking) == .inactive)
    }

    @Test func anUnbalancedReleaseCannotFreeAStillHeldUse() {
        var policy = AudioSessionPolicy()
        policy.acquire(.haptics)
        #expect(policy.release(.speaking) == .silentHold)
        #expect(policy.release(.speaking) == .silentHold)
        #expect(policy.holds(.haptics))
        #expect(policy.release(.haptics) == .inactive)
        #expect(!policy.holds(.haptics))
    }
}
