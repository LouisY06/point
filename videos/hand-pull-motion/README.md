# Hand pull animation

This composition keeps the user's supplied sketch and embedded microphone. It bends the original index and thumb artwork with a deterministic 2D mesh, closes a pinch, pulls a native banner from the left, and exits to the right. This is an articulated cutout illustration, not a generated realistic hand video.

The alpha delivery master is `renders/hand-pull-alpha.mov`: ProRes 4444, 780 × 920, 30 fps, 2.30 seconds. The app transcodes this to HEVC with alpha for delivery. The map, dark banner and speech text stay in SwiftUI; none are baked into the master.

`renders/hand-pull-poster.png` is the exact decoded first frame on the same full canvas. Use this as the idle image to avoid any still/video alignment jump. The mic is retained.

`timing.json` is the integration contract. Native banner movement derives from video playback time. For t between 0.78 and 1.65 seconds, normalize u = (t − 0.78) / 0.87, clamp to 0…1, calculate p = u²(3 − 2u), and place the banner edge at x = −10 + 420p on a 390 × 460 logical canvas. Contact sits at y = 205. The original idle image bounds are x = 95.0709, y = 30, width = 219.8582, height = 400.

The wrist is clipped at source y = 1515. This makes a perfectly straight horizontal cut without changing the source's original 1692-pixel canvas or stretching the artwork. The mic, hand proportions and hatching stay unchanged.

## Source and preview

Production source is `index.html`. Edit `scripts/motion.js`, then run `node scripts/build.mjs` to synchronize the inline composition and preview. The `preview` project is only a standalone motion proof with a diagrammatic background and temporary banner; it is not the production map UI. Its rendered proof is `renders/hand-pull-banner-preview.mp4`.

The earlier ragged-wrist version is preserved as `renders/hand-pull-alpha-ragged-backup.mov`.

## Verification

Run `npx hyperframes check` and inspect proof frames. The MOV should report codec `prores`, pixel format `yuva444p12le`, 30 fps, and duration 2.300 seconds. Decode a frame and confirm exterior alpha 0 and an opaque palm. Confirm the final frames are completely transparent after the hand exits.

Final production and preview compositions passed HyperFrames lint, runtime and layout checks with no errors or warnings. The visible pinch, stable embedded mic, straight wrist, and rightward exit were inspected in snapshots and encoded frames.
