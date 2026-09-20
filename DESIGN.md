# Point design

An outdoor pedestrian checks a phone in daylight, speaks a destination, then puts attention back on their surroundings. The user subsequently requested a white glove outline as the app interface. Use a dark, high-contrast home so the outline and voice control are legible. The app currently opens in dark appearance.

## Direction

Restrained color, one expressive voice control, generous space, native SF typography. Voice is the center of the home screen; geography becomes the center after selection. Avoid dashboards and stacked status cards.

## Color

Primary seed: OKLCH(0.600 0.124 70). Deepen to OKLCH(0.51 0.12 70) for readable interactive text on white. The route uses OKLCH(0.66 0.14 70); use charcoal, not small text, against this brighter route accent. Surfaces use semantic iOS systemBackground and label colors, adapting to dark mode. Swift converts the OKLCH seed to sRGB at the token boundary.

Use `PointTheme.action` for standalone controls: light gold OKLCH(0.80 0.12 80) in dark appearance, deep gold in light appearance. Filled actions use `PointFilledButtonStyle`, pairing white labels with the deep gold fill (5.89:1 contrast); disabled labels remain readable on charcoal. Do not apply a white tint to filled native buttons. Camera controls sit on opaque semantic surfaces so camera brightness cannot wash out their text. The home test button uses white text on a dark backing over the map, in the fixed top bar beside device setup. It falls back to its viewfinder icon when space is tight. Home content only scrolls when it exceeds the available height; fitting content has no scroll bounce.

## Typography and layout

SF Pro semantic styles. The home title is a quiet 36-point display moment, using a scaled metric. All other text uses system styles. Horizontal inset 28 points, touch targets at least 48. The microphone is 56 points and sits inside a compact native hand outline. The only home text is the wordmark, “Where to?”, “Tap to speak”, and a small Preview action. Route controls form one bottom surface, not a dashboard.

## Motion

Voice input: a microphone becomes a waveform while actually recording. Search: a restrained progress arc. Route reveal: the circular voice region expands into the map over 650 ms; destination controls enter over 240 ms. All functional content appears immediately with Reduce Motion; no waiting for the animation to finish. Route fitting is animated once per route identity, never on each location tick.

## Accessibility

Do not use color, waveform motion, or vibration as the only status communication. Use plain status text and VoiceOver announcements. No fake “connected” indicator. Demo navigation is explicitly labeled and never mistaken for a live route. Keep Apple Maps attribution visible on both sample and live maps.

## Transit surfaces

Route choices use transit badges followed by walking time, transfer count, boarding stop, and alighting stop. Use semantic primary text inside these tappable rows; the action tint must not turn the whole itinerary blue. Transit badges calculate black or white label contrast against their line color.

The trip panel has a 44-point drag/tap handle and a bounded, scrollable body. Its collapsed height follows the current instruction and action, including wrapped text; hidden itinerary rows must not peek out at the bottom. Once a trip starts, prioritize its current instruction over the destination address. Keep body text fully scalable; cap only map annotations, decorative status glyphs, and the compact map toolbar at XXXL. At accessibility sizes, the panel scrolls when the header exceeds its maximum height. A collapsed panel returns to the top of its content when closed.

Use bus symbols for buses and train symbols for rail, label boarding overrides explicitly, and keep “I'm on board” / “I'm off” available without live vehicle data. Completed map legs fade without resetting the camera. Simulated transit data is only available through explicit debug launch arguments.

## Motion reference

Apple, [Enhance your UI animations and transitions](https://developer.apple.com/videos/play/wwdc2024/10145/): source continuity and interruption-friendly transitions. This implementation uses that principle rather than adding unrelated decorative motion.

## Latest user direction

The current glove is a native vector outline using Apple’s proportioned hand.raised symbol. A standalone white microphone sits inside the palm with no visible circular backplate and an invisible 56-point tap target. The map portal expands from that exact control position using linear interpolation with a monotonic easing curve. A finer sketch-style hand is being refined separately; it is not yet approved or included in the app bundle. The proposed hand-pulls-transcript animation follows still-artwork approval.

The home background is a lightly blurred monochrome map under slowly drifting charcoal, cool silver, and muted gold gradients. Keep streets recognizable with a 2-point blur, light dimming, and an 82% atmosphere layer. Slightly stronger silver and muted gold light, with a broader feathered reflection, adds a more noticeable satin sheen. The map itself stays still; only the atmospheric light moves, on a separate 30 fps canvas. Motion pauses when the app is inactive, a destination sheet is open, or the route is visible. Reduce Motion uses a static composition, and Increase Contrast softens the highlights. The outline shifts 10 points right relative to its original placement. The map reveal removes the background atmosphere through the expanding portal.

## Temporary voice preview

Tapping the glove plays a cancellable, simulated sequence: waveform and word-by-word “Take me to Shake Shack”, a 1.5-second route preparation indicator, then the map portal. No microphone, speech model, or routes API is called in this preview. Live voice remains opt-in through POINT_LIVE_VOICE.

## Indoor demo

Keep the camera prominent. Use a compact headline navigation bar, a title2 semibold task heading, one body instruction with 3-point extra line spacing, and body-size actions. Beacon counts communicate route setup; technical and privacy details belong in Demo help. Use a content-height bottom panel capped at 56% of the available height with scrolling for large Dynamic Type. Keep all text on opaque semantic surfaces. The floor cursor is a world-space gold ring at the exact anchor placement point. Tall beacons grow upward over 380 ms, or fade with Reduce Motion.
