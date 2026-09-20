import Foundation

@MainActor public protocol SpeechSynthesizing {
    func synthesize(_ text: String) async throws -> SpeechAudio
}

public enum SpeechError: Error { case invalidText }
