# Voice setup

## Local phone configuration

1. Copy `.env.example` to `.env` if you do not already have a local file.
2. Fill in the OpenAI and Deepgram **secret API keys**. Never commit `.env` or add it as an Xcode resource.
3. Build and run the Debug app on your iPhone. Use `xcrun devicectl list devices` to find its identifier.
4. Copy the configuration after installation:

```sh
xcrun devicectl device copy to --device YOUR_DEVICE_ID \
  --domain-type appDataContainer --domain-identifier com.point.navigator \
  --source .env --destination Documents/dev.env
```

The app reloads configuration for each completed recording and spoken reply. Repeat the copy after editing `.env`; no app rebuild is needed for key or voice changes. Uninstalling the app deletes this configuration. An unshared Xcode run scheme can also supply these variables; nonempty scheme values take precedence.

## Voice choice

Spoken replies use Deepgram Flux TTS. The default voice is `flux-hannah-en`; `flux-miles-en` is the calm masculine alternative. The intended delivery is calm, concise and slightly slower, with restrained expression: set `DEEPGRAM_VOICE_SPEED` between `0.7` and `1.2` and `DEEPGRAM_EXPRESSIVITY` between `-2` (calm) and `2` (animated). Audition a voice on the phone before finalizing it for navigation; `DEEPGRAM_VOICE` selects another to compare.

Flux is chosen for short responses and low latency. MP3 output is played by `AVAudioPlayer`. The current implementation downloads each complete short utterance before playback; the `/v2/speak` response carries no word timings, so captions are spread evenly across the measured audio length and revealed against the playhead. It does not yet stream audio. [Speech endpoint documentation](https://developers.deepgram.com/docs/tts-rest).

## Conversation behavior

- Tap the hand and speak. Apple Speech displays live words; OpenAI returns the final transcript when configured. Recording now waits for three seconds of continuously observed quiet after recognized words. Ongoing sound keeps it open even if recognition callbacks stall; without live words, sustained audio needs a four-second quiet tail. Tap again to finish sooner. No-speech is reported only after twelve seconds and a fresh three-second quiet stretch. Missing audio samples do not count as silence. Sixty seconds is the hard recording limit.
- After a clarification or confirmation question finishes playing, Point automatically listens for the answer. A 250 ms speaker-tail gap precedes microphone capture, then a soft haptic and Listening label mark the handoff. This follows actual Deepgram/system playback completion or a completed VoiceOver announcement. Cancel, typing, device setup, app inactivity and interrupted speech disarm the handoff. Silence and permission errors wait for an explicit retry; route-ready/navigation announcements do not reopen the microphone.
- Apple Maps resolves the destination and builds the route. The app speaks the destination and street only (no city, state, postcode or country) and asks you to tap Start. Ambiguous searches speak a chooser prompt.
- Navigation start, arrival, off-route detection and errors also have spoken feedback. This does not add automatic rerouting or obstacle guidance.
- A new reply replaces the old one. Starting a recording, cancelling or leaving the app cancels pending speech and stops playback. Calls/audio interruptions also cancel speech. The app does not auto-resume an old spoken reply. Point replies show the small hand avatar and reveal each word at its estimated place in the Deepgram audio. The system-voice fallback uses native speech word callbacks.
- Without Deepgram, or on service/network/audio failure, the system voice is used. With VoiceOver active, accessibility announcements take precedence.

OpenAI also interprets city-only requests, follow-ups, candidate selections and corrections. Point asks for a specific place in a city, confirms trips into another city and walks over 45 minutes, and accepts yes/no replies. Confirming shows route review; it never automatically starts a journey. See [conversation cases](POINT_AI_SCENARIOS.md), including future bike-mode policy.

## Validation

`swift test` covers credential parsing, HTTP requests and failures, system fallback, and stale/cancelled speech suppression without contacting either provider. The iOS target exercises audio playback through its device build; physical microphone/playback transitions still need hands-on testing.

Release builds do not load these development secrets. Distribution requires authenticated backend implementations of the speech protocols.
