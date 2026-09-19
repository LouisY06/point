# Hand-led voice interaction

Updated September 19, 2026. The user approved production and selected a new hand. The previous drawing remains a backup.

## Artwork

- Preferred source: `output/hand-interaction/source-hand-preferred.png` (user supplied).
- Preferred transparent texture: `App/Assets.xcassets/HandPreferred.imageset/hand.png`.
- Previous drawing: `App/Assets.xcassets/HandBackup.imageset/hand.png`; its original source and cutout also remain under `output/hand-interaction/`.
- Preserve the embedded microphone. The app adds an invisible native button over the artwork, without a circle or duplicate glyph.
- The user requested a flat wrist. Clip the source at y=1515 on its 930×1692 canvas, without resizing or recentering. The still and every animation frame use the same cut. Do not restore the earlier ragged edge.

The cutout was prepared using the built-in image-generation tool, removing only exterior paper and finger gaps. Its pale interior and irregular dark hatching remain. A subsequent generated flat-edge attempt changed the canvas and was rejected; the exact flat cut is applied by the native view and animation renderer instead.

## Opening sequence

Canonical canvas: 390×460 points, rendered at 780×920, 30 fps. Idle texture rect: x=95.07, y=30, width=219.86, height=400. Total clip duration: 2.30 seconds.

| Time | Action |
| --- | --- |
| 0–0.10 s | Hold the identical still pose. |
| 0.10–0.65 s | Reach left; the index and thumb articulate into a pinch. |
| 0.65–0.78 s | Hold contact. |
| 0.78–1.65 s | Pull the banner's leading edge from left to right. |
| 1.65–2.18 s | Release and exit to the right. |
| 2.18–2.30 s | Transparent tail, then stop decoding. |

During the pull, u=clamp((t−0.78)/0.87, 0, 1), and edgeX=−10+420×u²×(3−2u). The contact height is approximately y=205. The native banner clamps its edge into the visible 0–390 range. The movie and banner use the same playback clock and coordinate system.

The background remains the existing blurred native map. The banner is a charcoal horizontal surface at y=150 with a nominal height of 210 points. It covers only the reading area. Its text moves with the banner; the hand passes in front, then leaves the words in focus.

## Deliverables and integration

- Editable HyperFrames project: `videos/hand-pull-motion/`.
- Alpha production master: `videos/hand-pull-motion/renders/hand-pull-alpha.mov` (ProRes 4444).
- iOS delivery clip: `App/Resources/HandMotion/hand-pull.mov` (HEVC with alpha).
- Native playback: `App/HandMotionPlayer.swift` hosts a transparent AVPlayerLayer and exposes its playhead.
- Native content: `App/HandVoiceInteraction.swift` owns the banner, transcript, activity indication and controls.

Only the hand is baked into the movie. The transcript, banner, map and controls remain native SwiftUI views. The still stays visible until the first video frame is ready. The player is paused and releases its item after completion, cancellation or leaving the screen. A failed/stalled decorative clip falls back to the listening surface. Reduce Motion skips the movie. Accessibility text sizes also use the simpler transition and a larger, scrollable transcript area.

Cancellation stops the demo/recording and the movie; typing or opening device setup also cancels the current voice flow. Repeated taps cannot create overlapping demos. Returning from the map restores the still.

## Temporary demo and future live speech

The default tap flow remains a visual demo, as requested. It waits for the opening, displays “Take me to Shake Shack” word by word, shows a route-processing state, then reveals the existing synthetic sample route. No microphone input, paid API call or synthesized spoken reply is used in this mode. The banner identifies it as a voice preview; the map identifies the sample route.

The opt-in live recorder is unchanged: it records an M4A file, then sends it for batch transcription. It does not yet deliver partial transcripts or speech endpoint detection. Streaming speech-to-text and a spoken destination confirmation remain separate work. Start capture as soon as permission/session setup is ready, independently of decorative playback. Keep provider credentials on a backend. Resolve actual places and walking routes through the map service; do not invent destination addresses.

## Validation and remaining device check

Verify the rendered alpha track, a transparent first-frame corner, visible palm pixels, a completely transparent tail, matching still/video geometry, pinch contact, native demo-to-map transition, cancel/replay, keyboard fallback and larger text. A physical iPhone check is still required for final decoder/power evaluation; simulator playback is not evidence of hardware power use.

Apple's transparent-video guidance: https://developer.apple.com/videos/play/wwdc2019/506/
