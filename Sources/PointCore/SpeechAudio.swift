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

    /// The same audio with cues spread evenly over `duration`, for synthesizers that return no
    /// word timings. Captions then keep pace with speech rather than appearing only at the end.
    public func withEstimatedCues(duration: Double) -> SpeechAudio {
        guard words.isEmpty, duration.isFinite, duration > 0 else { return self }
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return self }
        // Trailing silence and the last word's own length mean the final cue lands a little early.
        let step = duration * 0.92 / Double(tokens.count)
        var cues: [WordCue] = []
        var prefix = ""
        for (index, token) in tokens.enumerated() {
            prefix += (prefix.isEmpty ? "" : " ") + token
            cues.append(WordCue(seconds: Double(index) * step, prefix: prefix))
        }
        return SpeechAudio(data: data, text: text, words: cues)
    }
}
