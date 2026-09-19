import Foundation

@MainActor public protocol SpeechPlaying: AnyObject {
    func play(_ audio: SpeechAudio, progress: @escaping (String) -> Void, completion: @escaping (Bool) -> Void) throws
    func speakSystem(_ text: String, progress: @escaping (String) -> Void, completion: @escaping (Bool) -> Void)
    func stop()
}

/// A newer prompt always supersedes an older one. Cancelled requests never speak a late reply.
@MainActor public final class SpokenFeedback {
    private let player: any SpeechPlaying
    private let synthesizer: () -> (any SpeechSynthesizing)?
    private var pending: Task<Void, Never>?
    private var generation = UUID()
    private let onProgress: (String) -> Void
    public private(set) var usedSystemFallback = false

    public init(player: any SpeechPlaying, onProgress: @escaping (String) -> Void = { _ in },
                synthesizer: @escaping () -> (any SpeechSynthesizing)?) {
        self.player = player
        self.synthesizer = synthesizer
        self.onProgress = onProgress
    }

    public func speak(_ text: String, onFinished: @escaping () -> Void = {}) {
        stop()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onProgress("")
        let request = generation
        let progress: (String) -> Void = { [weak self] prefix in
            guard let self, self.generation == request else { return }
            self.onProgress(prefix)
        }
        let completion: (Bool) -> Void = { [weak self] succeeded in
            guard let self, self.generation == request else { return }
            // Only natural playback completion hands the conversation back to the listener.
            // Invalidate before calling out so duplicate or late delegate events cannot reopen it.
            self.generation = UUID()
            self.pending = nil
            if succeeded { onFinished() }
        }
        guard let service = synthesizer() else {
            usedSystemFallback = true
            player.speakSystem(text, progress: progress, completion: completion)
            return
        }
        pending = Task { [weak self] in
            do {
                let audio = try await service.synthesize(text)
                guard let self, generation == request, !Task.isCancelled else { return }
                try player.play(audio, progress: progress, completion: completion)
            } catch {
                guard let self, generation == request, !Task.isCancelled, !(error is CancellationError) else { return }
                usedSystemFallback = true
                player.speakSystem(text, progress: progress, completion: completion)
            }
        }
    }

    public func stop() {
        generation = UUID()
        pending?.cancel()
        pending = nil
        usedSystemFallback = false
        player.stop()
    }
}
