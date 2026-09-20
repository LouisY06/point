import Testing
@testable import PointCore

struct ConversationTests {
    @Test func voiceCommandsDoNotStealDestinations() {
        #expect(ConversationCommand.parse("I’m on board") == .boarded)
        #expect(ConversationCommand.parse("Say that again!") == .repeatReply)
        #expect(ConversationCommand.parse("stop listening") == .endConversation)
        #expect(ConversationCommand.parse("pause route") == .pause)
        #expect(ConversationCommand.parse("take me to Start Cafe") == nil)
        #expect(ConversationCommand.parse("don't start walking") == nil)
        #expect(ConversationCommand.parse("when should I get off") == nil)
    }
    @Test func interruptionNeedsRecentVoiceAndWordsAndRejectsReplyEcho() {
        var detector = SpeechInterruptionDetector()
        #expect(!detector.shouldInterrupt(transcript: "Actually Boston", assistantText: "Which city?", at: 0))
        for i in 0...10 { detector.observeAudio(levelDB: -35, at: Double(i) / 20) }
        #expect(!detector.shouldInterrupt(transcript: "", assistantText: "Which city?", at: 0.5))
        #expect(!detector.shouldInterrupt(transcript: "Which", assistantText: "Which city?", at: 0.5))
        #expect(!detector.shouldInterrupt(transcript: "Which city", assistantText: "Which city?", at: 0.5))
        #expect(detector.shouldInterrupt(transcript: "Actually Boston", assistantText: "Which city?", at: 0.5))
        #expect(!detector.shouldInterrupt(transcript: "Actually Boston", assistantText: "Which city?", at: 2))
    }
    @Test func briefNoiseDoesNotInterrupt() {
        var detector = SpeechInterruptionDetector()
        detector.observeAudio(levelDB: -25, at: 0)
        detector.observeAudio(levelDB: -25, at: 0.05)
        #expect(!detector.shouldInterrupt(transcript: "hello", assistantText: "Where to?", at: 0.05))
    }
    @Test func conversationalPauseFinishesWithoutAButtonAndKeepsShortPauses() {
        var detector = SpeechEndpointDetector(startedAt: 0, pauseDuration: 1.6)
        detector.observeTranscript(at: 1)
        for i in 10...24 { detector.observeAudio(levelDB: -70, at: Double(i) / 10) }
        #expect(detector.endpoint(at: 2.4) == .listening)
        detector.observeTranscript(at: 2.4)
        for i in 25...41 { detector.observeAudio(levelDB: -70, at: Double(i) / 10) }
        #expect(detector.endpoint(at: 4.1) == .finished)
    }
}
