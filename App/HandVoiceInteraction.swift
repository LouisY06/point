import SwiftUI

/// The movie is only the hand. Speech, loading state and controls stay native.
struct HandVoiceInteraction: View {
    let active: Bool
    let listening: Bool
    let searching: Bool
    let transcript: String
    let isDemo: Bool
    let onSpeak: () -> Void
    let onFinish: () -> Void
    let onCancel: () -> Void
    let onType: () -> Void
    let onVoiceCenter: (CGPoint) -> Void

    @StateObject private var motion = HandMotionPlayer()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicType
    @ScaledMetric(relativeTo: .title) private var transcriptSize = 32
    @AccessibilityFocusState private var transcriptFocused: Bool

    private var simpleMotion: Bool { reduceMotion || dynamicType.isAccessibilitySize }

    var body: some View {
        GeometryReader { geometry in
            let scale = geometry.size.width / HandMotionTiming.width
            let bannerEdge = HandMotionTiming.bannerEdge(at: motion.seconds)
            let posterRect = HandMotionTiming.stillRect
            let bannerHeight = max(210 * scale, transcriptSize * (dynamicType.isAccessibilitySize ? 5.5 : 3.8))
            ZStack(alignment: .topLeading) {
                listeningBanner
                    .frame(width: geometry.size.width, height: bannerHeight)
                    .background(Color(red: 0.035, green: 0.04, blue: 0.045).opacity(0.97))
                    .offset(x: simpleMotion ? 0 : (bannerEdge - HandMotionTiming.width) * scale,
                            y: 150 * scale)
                    .opacity(active && (motion.seconds > 0.78 || motion.finished) ? 1 : 0)
                    .allowsHitTesting(active && motion.finished)
                    .accessibilityHidden(!active || !motion.finished)

                Button(action: onSpeak) {
                    GloveOutline()
                        .frame(width: posterRect.width * scale, height: posterRect.height * scale)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .position(x: posterRect.midX * scale, y: posterRect.midY * scale)
                .opacity(!active || (!motion.frameReady && !motion.finished) ? 1 : 0)
                .allowsHitTesting(!active)
                .accessibilityHidden(active)
                .accessibilityLabel("Speak a destination")
                .accessibilityHint("Plays a preview: take me to Shake Shack")

                TransparentHandMovie(motion: motion)
                    .frame(width: geometry.size.width, height: HandMotionTiming.height * scale)
                    .opacity(active && motion.frameReady && motion.running ? 1 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                HStack(spacing: 24) {
                    Button(action: onType) {
                        Image(systemName: "keyboard").font(.title3).frame(width: 48, height: 48)
                    }
                    .accessibilityLabel("Type a destination instead")
                    if active {
                        if !isDemo && !searching {
                            Button("Finish", action: onFinish).frame(minHeight: 48)
                        }
                        Button("Cancel", role: .cancel, action: onCancel).frame(minHeight: 48)
                    } else {
                        Text("Tap to speak").font(.subheadline).foregroundStyle(.white.opacity(0.8))
                            .accessibilityHidden(true)
                    }
                }
                .foregroundStyle(.white)
                .frame(width: geometry.size.width)
                .position(x: geometry.size.width / 2, y: max(442 * scale, 150 * scale + bannerHeight + 42))
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .onAppear {
                let frame = geometry.frame(in: .named("screen"))
                onVoiceCenter(CGPoint(x: frame.minX + 225 * scale, y: frame.minY + 238 * scale))
                if active { motion.start(reduceMotion: simpleMotion) }
            }
        }
        .aspectRatio(HandMotionTiming.width / (dynamicType.isAccessibilitySize ? 400 + transcriptSize * 5.5 : 480), contentMode: .fit)
        .onChange(of: active) { _, active in
            if active { motion.start(reduceMotion: simpleMotion) }
            else { motion.reset() }
        }
        .onChange(of: simpleMotion) { _, simple in
            if simple && active { motion.finish(fallback: true) }
        }
        .onChange(of: motion.finished) { _, finished in
            if finished && active { transcriptFocused = true }
        }
        .onDisappear { motion.reset() }
    }

    private var listeningBanner: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 9) {
                VoiceActivity(searching: searching, quiet: simpleMotion || (!listening && !searching))
                    .frame(width: 22, height: 18)
                    .accessibilityHidden(true)
                Text(searching ? "Finding your route…" : isDemo ? "Voice preview" : "Listening")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.76))
            }
            ScrollViewReader { scroll in
                ScrollView {
                    Text(transcript.isEmpty ? "Speak into mic…" : transcript)
                        .font(.system(size: transcriptSize, weight: .medium))
                        .tracking(-0.5)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                        .animation(.easeOut(duration: 0.16), value: transcript)
                        .accessibilityFocused($transcriptFocused)
                    Color.clear.frame(height: 1).id("utterance-end").accessibilityHidden(true)
                }
                .scrollIndicators(.hidden)
                .onChange(of: transcript) { _, _ in scroll.scrollTo("utterance-end", anchor: .bottom) }
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

private struct VoiceActivity: View {
    let searching: Bool
    let quiet: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: quiet)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<4) { index in
                    let wave = abs(sin(time * (searching ? 2.4 : 5) - Double(index) * 0.7))
                    Capsule().fill(.white.opacity(searching ? 0.45 + 0.55 * wave : 0.9))
                        .frame(width: 3, height: quiet ? 10 : searching ? 4 : 5 + 12 * wave)
                }
            }
        }
    }
}
