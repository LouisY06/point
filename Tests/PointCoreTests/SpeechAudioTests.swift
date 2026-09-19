import Foundation
import Testing
@testable import PointCore

struct SpeechAudioTests {
    @Test func wordsRevealAtAudioTimeIncludingPunctuation() throws {
        let text = "Are you sure?"
        let times = Array(text).indices.map { Double($0) / 10 }
        let words = try SpeechAudio.wordCues(characters: Array(text).map(String.init), starts: times)
        let audio = SpeechAudio(data: Data(), text: text, words: words)
        #expect(audio.visibleText(at: -1) == "")
        #expect(audio.visibleText(at: 0) == "Are")
        #expect(audio.visibleText(at: 0.4) == "Are you")
        #expect(audio.visibleText(at: 0.8) == "Are you sure?")
    }

    @Test func missingOrInvalidTimingsAreRejectedInsteadOfInventingPacing() {
        #expect(throws: (any Error).self) { try SpeechAudio.wordCues(characters: ["H", "i"], starts: [0]) }
        #expect(throws: (any Error).self) { try SpeechAudio.wordCues(characters: ["H", "i"], starts: [1, 0]) }
        #expect(throws: (any Error).self) { try SpeechAudio.wordCues(characters: ["H"], starts: [.nan]) }
    }
}
