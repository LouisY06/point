import Foundation
import Testing
@testable import PointCore

struct SpeechAudioTests {
    @Test func wordsRevealAtAudioTimeIncludingPunctuation() {
        let words = [SpeechAudio.WordCue(seconds: 0, prefix: "Are"),
                     SpeechAudio.WordCue(seconds: 0.4, prefix: "Are you"),
                     SpeechAudio.WordCue(seconds: 0.8, prefix: "Are you sure?")]
        let audio = SpeechAudio(data: Data(), text: "Are you sure?", words: words)
        #expect(audio.visibleText(at: -1) == "")
        #expect(audio.visibleText(at: 0) == "Are")
        #expect(audio.visibleText(at: 0.4) == "Are you")
        #expect(audio.visibleText(at: 0.8) == "Are you sure?")
    }

    @Test func estimatedCuesPaceTheWholeReplyAndLandBeforeTheAudioEnds() {
        let audio = SpeechAudio(data: Data(), text: "Are you sure?").withEstimatedCues(duration: 3)
        #expect(audio.visibleText(at: 0) == "Are")
        #expect(audio.visibleText(at: 1) == "Are you")
        #expect(audio.visibleText(at: 2.9) == "Are you sure?")
        #expect(audio.words.last?.seconds ?? .infinity < 3)
    }

    @Test func unusableDurationsAndRealTimingsAreLeftAlone() {
        let text = "Are you sure?"
        #expect(SpeechAudio(data: Data(), text: text).withEstimatedCues(duration: 0).words.isEmpty)
        #expect(SpeechAudio(data: Data(), text: text).withEstimatedCues(duration: .nan).words.isEmpty)
        #expect(SpeechAudio(data: Data(), text: "  ").withEstimatedCues(duration: 3).words.isEmpty)
        let timed = SpeechAudio(data: Data(), text: text, words: [SpeechAudio.WordCue(seconds: 9, prefix: text)])
        #expect(timed.withEstimatedCues(duration: 3).words.map(\.seconds) == [9])
    }
}
