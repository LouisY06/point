import Foundation

public struct SpeechAudio {
    public struct WordCue: Equatable {
        public let seconds: Double
        public let prefix: String
    }
    public let data: Data
    public let text: String
    public let words: [WordCue]

    public init(data: Data, text: String, words: [WordCue] = []) {
        self.data = data; self.text = text; self.words = words
    }

    public func visibleText(at seconds: Double) -> String {
        words.last(where: { $0.seconds <= seconds })?.prefix ?? ""
    }

    public static func wordCues(characters: [String], starts: [Double]) throws -> [WordCue] {
        guard !characters.isEmpty, characters.count == starts.count,
              starts.allSatisfy({ $0.isFinite && $0 >= 0 }), zip(starts, starts.dropFirst()).allSatisfy({ $0 <= $1 }) else {
            throw ServiceError.invalidResponse
        }
        var cues: [WordCue] = []
        var prefix = ""
        var wordStart: Double?
        for (character, time) in zip(characters, starts) {
            let whitespace = character.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if whitespace, let start = wordStart {
                cues.append(WordCue(seconds: start, prefix: prefix.trimmingCharacters(in: .whitespacesAndNewlines)))
                wordStart = nil
            } else if !whitespace, wordStart == nil { wordStart = time }
            prefix += character
        }
        if let wordStart { cues.append(WordCue(seconds: wordStart, prefix: prefix.trimmingCharacters(in: .whitespacesAndNewlines))) }
        guard !cues.isEmpty else { throw ServiceError.invalidResponse }
        return cues
    }
}
