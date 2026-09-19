import AVFoundation
import CoreImage
import SwiftUI
import UIKit

/// The same geometry and timing used by videos/hand-pull-motion. All values are
/// in its 390 × 460 logical canvas; scale the movie and banner together.
enum HandMotionTiming {
    static let width: CGFloat = 390
    static let height: CGFloat = 460
    static let duration = 2.30
    static let stillRect = CGRect(x: 95.07, y: 30, width: 219.86, height: 400)
    static let bannerRect = CGRect(x: 16, y: 124, width: 358, height: 208)
    static let bannerRadius: CGFloat = 18

    static func bannerEdge(at seconds: Double) -> CGFloat {
        let u = min(1, max(0, (seconds - 0.78) / 0.87))
        // This receives the displayed pixel buffer's presentation timestamp,
        // never the player's independently advancing clock.
        let progress = u * u * u * (u * (u * 6 - 15) + 10)
        return -12 + (bannerRect.maxX + 12) * progress
    }
}

@MainActor final class HandMotionPlayer: ObservableObject {
    struct Frame {
        let image: CGImage
        let seconds: Double
    }

    enum PlaybackState {
        case idle
        case playing(Frame?)
        case finished(fallback: Bool)
    }

    // A single publication pairs the image with its exact timestamp. SwiftUI
    // commits the hand and panel together, even when display frames are skipped.
    @Published private(set) var state: PlaybackState = .idle

    var frame: Frame? {
        if case let .playing(frame) = state { return frame }
        return nil
    }
    var running: Bool {
        if case .playing = state { return true }
        return false
    }
    var finished: Bool {
        if case .finished = state { return true }
        return false
    }
    var usesFallback: Bool {
        if case let .finished(fallback) = state { return fallback }
        return false
    }
    var seconds: Double { finished ? HandMotionTiming.duration : frame?.seconds ?? 0 }
    var frameReady: Bool { frame != nil }

    private let player = AVPlayer()
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var videoOutput: AVPlayerItemVideoOutput?
    private var displayLink: CADisplayLink?
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
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int]()
        ])
        output.suppressesPlayerRendering = true
        item.add(output)
        videoOutput = output
        player.replaceCurrentItem(with: item)
        state = .playing(nil)
        itemObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let failed = item.status == .failed
            Task { @MainActor in
                guard let self, self.generation == token, failed else { return }
                self.finish(fallback: true)
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.finish(fallback: false)
            }
        }
        let target = DisplayLinkTarget(owner: self)
        let link = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        displayLink = link
        link.add(to: .main, forMode: .common)
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

    private func displayFrame(at hostTime: CFTimeInterval) {
        guard running, let output = videoOutput else { return }
        let requestedTime = output.itemTime(forHostTime: hostTime)
        guard requestedTime.isNumeric, output.hasNewPixelBuffer(forItemTime: requestedTime) else { return }
        var presentationTime = CMTime.invalid
        guard let buffer = output.copyPixelBuffer(forItemTime: requestedTime, itemTimeForDisplay: &presentationTime) else { return }
        guard presentationTime.isNumeric else {
            finish(fallback: true)
            return
        }
        let source = CIImage(cvPixelBuffer: buffer)
        guard let image = imageContext.createCGImage(source, from: source.extent, format: .RGBA8, colorSpace: colorSpace) else {
            finish(fallback: true)
            return
        }
        state = .playing(Frame(image: image, seconds: min(HandMotionTiming.duration, max(0, presentationTime.seconds))))
    }

    func finish(fallback: Bool) {
        generation = UUID()
        clearPlayback()
        withAnimation(fallback ? .easeOut(duration: 0.18) : nil) {
            state = .finished(fallback: fallback)
        }
    }

    func reset() {
        generation = UUID()
        clearPlayback()
        state = .idle
    }

    private func clearPlayback() {
        watchdog?.cancel()
        watchdog = nil
        displayLink?.invalidate()
        displayLink = nil
        player.pause()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        itemObserver?.invalidate()
        itemObserver = nil
        player.replaceCurrentItem(with: nil)
        videoOutput = nil
    }

    // CADisplayLink retains its target. This proxy leaves ownership with the view.
    @MainActor private final class DisplayLinkTarget: NSObject {
        weak var owner: HandMotionPlayer?
        init(owner: HandMotionPlayer) { self.owner = owner }
        @objc func tick(_ link: CADisplayLink) {
            owner?.displayFrame(at: link.targetTimestamp)
        }
    }
}
