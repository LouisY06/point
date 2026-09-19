# Hand pull animation

This composition keeps the user's supplied sketch and embedded microphone. A deterministic 2D mesh closes a pad-to-pad pinch, rolls and slightly foreshortens the whole hand, pulls a native banner from the left, and exits to the right. The index lies in front of the banner and the thumb behind it. This is an articulated cutout illustration, not a generated realistic hand video.

The alpha delivery master is `renders/hand-pull-alpha.mov`: ProRes 4444, 780 × 920, 30 fps, 2.30 seconds. The app transcodes this to HEVC with alpha for delivery. The map, dark banner and speech text stay in SwiftUI; none are baked into the master.

`renders/hand-pull-poster.png` is the exact decoded first frame on the same full canvas. Use this as the idle image to avoid any still/video alignment jump. The mic is retained.

`timing.json` is the integration contract. Native banner movement derives directly from video playback time, quantized to the same 30fps sample held by the movie. Between 0.78 and 1.65 seconds, normalize u = (t − 0.78) / 0.87, clamp to 0…1, calculate p = u³(6u² − 15u + 10), and lerp the banner's right edge from −12 to 374 on a 390 × 460 logical canvas. This gives zero velocity and acceleration at both ends. No independent SwiftUI spring or animation is added. Contact stays at x = edge − 8, y = 181 throughout the pull, even as the wrist settles.

The final native panel is x16, y124, width358, height208 with circular 18px corners and an opaque charcoal fill. The video contains a moving alpha matte that removes the **rear thumb and palm** under this panel; only the index is in front, preventing the palm/thumb joint from leaking a clipped sliver. Render the native panel below the movie; do not change panel geometry, transparency, or timing independently. The index is composited last and reaches beyond the edge, placing the grip on its broad distal pad instead of the fingertip. Larger accessibility layouts skip the movie and show a resized native panel directly.

The original idle image bounds remain x = 95.0709, y = 30, width = 219.8582, height = 400.

The wrist is clipped at source y = 1515. This makes a perfectly straight horizontal cut without changing the source's original 1692-pixel canvas or stretching the artwork. The mic, hand proportions and hatching stay unchanged.

## Source and preview

Production source is `index.html`. Edit `scripts/motion.js`, then run `node scripts/build.mjs` to synchronize the inline composition and preview. The `preview` project is only a standalone motion proof with a diagrammatic background and temporary banner; it is not the production map UI. Its rendered proof is `renders/hand-pull-banner-preview.mp4`.

The earlier ragged-wrist version is preserved as `renders/hand-pull-alpha-ragged-backup.mov`. The pre-refinement rig, timing and video are also saved under `output/hand-interaction/rig-before-refinement` at the repository root. Both source hand assets remain unchanged.

## Verification

Run `npx hyperframes check` and inspect proof frames. The MOV should report codec `prores`, pixel format `yuva444p12le`, 30 fps, and duration 2.300 seconds. Decode a frame and confirm exterior alpha 0 and an opaque palm. Confirm the final frames are completely transparent after the hand exits.

Inspect snapshots at 0, 0.45, 1.20, 1.48, 1.75 and 2.25 seconds. Check the finger pad crossing the panel edge, the thumb hidden behind it, wrist settling, stable embedded mic, flat wrist, and complete rightward exit. Native UI validation must also cover cancellation and replay, demo transcription, and the route reveal.
