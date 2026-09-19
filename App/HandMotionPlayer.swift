import AVFoundation
import SwiftUI
import UIKit

/// The same geometry and timing used by videos/hand-pull-motion. All values are
/// in its 390 × 460 logical canvas; scale the movie and banner together.
enum HandMotionTiming {
    static let width: CGFloat = 390
    static let height: CGFloat = 460
    static let duration = 2.30
    static let framesPerSecond = 30.0
    static let stillRect = CGRect(x: 95.07, y: 30, width: 219.86, height: 400)
    static let bannerRect = CGRect(x: 16, y: 124, width: 358, height: 208)
    static let bannerRadius: CGFloat = 18

    static func bannerEdge(at seconds: Double) -> CGFloat {
        let u = min(1, max(0, (seconds - 0.78) / 0.87))
        // The hand and native panel use the same eased lerp, with no second
        // SwiftUI animation to introduce lag between the grip and panel edge.
        let progress = u * u * u * (u * (u * 6 - 15) + 10)
        return -12 + (bannerRect.maxX + 12) * progress
    }
}

@MainActor final class HandMotionPlayer: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var seconds = 0.0
    @Published private(set) var frameReady = false
    @Published private(set) var running = false
    @Published private(set) var finished = false
    @Published private(set) var usesFallback = false

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var itemObserver: NSKeyValueObservation?
    private var watchdog: Task<Void, Never>?
    private var generation = UUID()

    init() {
        player.isMuted = true
        player.actionAtItemEnd = .pause
    }

    func start(reduceMotion: Bool) {
        reset()
        guard !reduceMotion,
              let url = Bundle.main.url(forResource: "hand-pull", withExtension: "mov") else {
            finish(fallback: true)
            return
        }
        let token = generation
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        running = true
        itemObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let failed = item.status == .failed
            Task { @MainActor in
                guard let self, self.generation == token, failed else { return }
                self.finish(fallback: true)
            }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 60), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self, self.generation == token, self.running else { return }
                let value = time.seconds
                if value.isFinite {
                    // The video holds each frame for 1/30s. Hold the banner on
                    // the same sample instead of letting it lead the matte.
                    let frameTime = floor(max(0, value) * HandMotionTiming.framesPerSecond) / HandMotionTiming.framesPerSecond
                    self.seconds = min(HandMotionTiming.duration, frameTime)
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.finish(fallback: false)
            }
        }
        player.play()
        // A missing/unsupported/stalled decorative movie must never block voice UI.
        watchdog = Task { [weak self] in
            var lastTime = -1.0
            var stalledChecks = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard let self, self.generation == token, self.running else { return }
                stalledChecks = self.seconds <= lastTime + 0.01 ? stalledChecks + 1 : 0
                lastTime = self.seconds
                if stalledChecks >= 3 {
                    self.finish(fallback: true)
                    return
                }
            }
        }
    }

    func displayReady(_ ready: Bool) {
        if running, ready { frameReady = true }
    }

    func finish(fallback: Bool) {
        generation = UUID()
        clearPlayback()
        usesFallback = fallback
        withAnimation(fallback ? .easeOut(duration: 0.18) : nil) {
            seconds = HandMotionTiming.duration
            running = false
            finished = true
        }
    }

    func reset() {
        generation = UUID()
        clearPlayback()
        seconds = 0
        frameReady = false
        running = false
        finished = false
        usesFallback = false
    }

    private func clearPlayback() {
        watchdog?.cancel()
        watchdog = nil
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        itemObserver?.invalidate()
        itemObserver = nil
        player.replaceCurrentItem(with: nil)
    }
}

/// AVPlayerLayer preserves the alpha track; VideoPlayer adds an opaque host/controls.
struct TransparentHandMovie: UIViewRepresentable {
    let motion: HandMotionPlayer

    func makeUIView(context: Context) -> PlayerSurface {
        let view = PlayerSurface()
        view.playerLayer.player = motion.player
        context.coordinator.observation = view.playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak motion] layer, _ in
            let ready = layer.isReadyForDisplay
            Task { @MainActor in motion?.displayReady(ready) }
        }
        return view
    }

    func updateUIView(_ uiView: PlayerSurface, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }
    static func dismantleUIView(_ uiView: PlayerSurface, coordinator: Coordinator) {
        coordinator.observation?.invalidate()
        uiView.playerLayer.player = nil
    }

    final class Coordinator { var observation: NSKeyValueObservation? }

    final class PlayerSurface: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isOpaque = false
            isUserInteractionEnabled = false
            playerLayer.backgroundColor = UIColor.clear.cgColor
            playerLayer.isOpaque = false
            playerLayer.videoGravity = .resizeAspect
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
}
