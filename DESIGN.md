# Point design

An outdoor pedestrian checks a phone in daylight, speaks a destination, then puts attention back on their surroundings. The user subsequently requested a white glove outline as the app interface. Use a dark, high-contrast home so the outline and voice control are legible. The app currently opens in dark appearance.

## Direction

Restrained color, one expressive voice control, generous space, native SF typography. Voice is the center of the home screen; geography becomes the center after selection. Avoid dashboards and stacked status cards.

## Color

Primary seed: OKLCH(0.600 0.124 70). Deepen to OKLCH(0.51 0.12 70) for readable interactive text on white. The route uses OKLCH(0.66 0.14 70); use charcoal, not small text, against this brighter route accent. Surfaces use semantic iOS systemBackground and label colors, adapting to dark mode. Swift converts the OKLCH seed to sRGB at the token boundary.

## Typography and layout

SF Pro semantic styles. The home title is a quiet 36-point display moment, using a scaled metric. All other text uses system styles. Horizontal inset 28 points, touch targets at least 48. The microphone is 56 points and sits inside a compact native hand outline. The only home text is the wordmark, “Where to?”, “Tap to speak”, and a small Preview action. Route controls form one bottom surface, not a dashboard.

## Motion

Voice input: a microphone becomes a waveform while actually recording. Search: a restrained progress arc. Route reveal: the circular voice region expands into the map over 650 ms; destination controls enter over 240 ms. All functional content appears immediately with Reduce Motion; no waiting for the animation to finish. Route fitting is animated once per route identity, never on each location tick.

## Accessibility

Do not use color, waveform motion, or vibration as the only status communication. Use plain status text and VoiceOver announcements. No fake “connected” indicator. Demo navigation is explicitly labeled and never mistaken for a live route. Keep Apple Maps attribution visible on both sample and live maps.

## Motion reference

Apple, [Enhance your UI animations and transitions](https://developer.apple.com/videos/play/wwdc2024/10145/): source continuity and interruption-friendly transitions. This implementation uses that principle rather than adding unrelated decorative motion.

## Latest user direction

The current glove is a native vector outline using Apple’s proportioned hand.raised symbol. A standalone white microphone sits inside the palm with no visible circular backplate and an invisible 56-point tap target. The map portal expands from that exact control position using linear interpolation with a monotonic easing curve. A finer sketch-style hand is being refined separately; it is not yet approved or included in the app bundle. The proposed hand-pulls-transcript animation follows still-artwork approval.

The home background is a lightly blurred monochrome map under slowly drifting charcoal, cool silver, and muted gold gradients. Keep streets recognizable with a 2-point blur, light dimming, and a 72% atmosphere layer. A narrow, feathered silver reflection adds a satin sheen. The map itself stays still; only the atmospheric light moves, on a separate 30 fps canvas. Motion pauses when the app is inactive, a destination sheet is open, or the route is visible. Reduce Motion uses a static composition, and Increase Contrast softens the highlights. The outline shifts 10 points right relative to its original placement. The map reveal removes the background atmosphere through the expanding portal.

## Temporary voice preview

Tapping the glove plays a cancellable, simulated sequence: waveform and word-by-word “Take me to Shake Shack”, a 1.5-second route preparation indicator, then the map portal. No microphone, speech model, or routes API is called in this preview. Live voice remains opt-in through POINT_LIVE_VOICE.
