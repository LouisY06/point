# Voice setup

## Local phone configuration

1. Copy `.env.example` to `.env` if you do not already have a local file.
2. Fill in the OpenAI and ElevenLabs **secret API keys**. ElevenLabs expects the secret beginning with `sk_`, not the key ID shown in the key list. Never commit `.env` or add it as an Xcode resource.
3. Build and run the Debug app on your iPhone. Use `xcrun devicectl list devices` to find its identifier.
4. Copy the configuration after installation:

```sh
xcrun devicectl device copy to --device YOUR_DEVICE_ID \
  --domain-type appDataContainer --domain-identifier com.point.navigator \
  --source .env --destination Documents/dev.env
```

The app reloads configuration for each completed recording and spoken reply. Repeat the copy after editing `.env`; no app rebuild is needed for key or voice changes. Uninstalling the app deletes this configuration. An unshared Xcode run scheme can also supply these variables; nonempty scheme values take precedence.

## Voice choice

Add the selected voice to your ElevenLabs Voice Library first. This was done for the configured development account. Start with [Caleb — Trusted Guide](https://elevenlabs.io/app/voice-library?search=AaOhDHYJ1XLZk74lXhdE), voice ID `AaOhDHYJ1XLZk74lXhdE`. The selected voice is masculine with an American accent and a grounded, conversational tone. The intended delivery is calm, concise and slightly slower (`0.95` speed), with restrained expression. Audition it on the phone before finalizing the voice for navigation. Set `ELEVENLABS_VOICE_ID` to another available voice to compare.

ElevenLabs lists Caleb as the replacement for Chris. Older default voices expire at the end of 2026 and may be unavailable to newer accounts, so this app does not default to Chris. [Official voice guidance](https://help.elevenlabs.io/hc/en-us/articles/26942950589969-What-are-Default-voices).

The speech model defaults to `eleven_flash_v2_5`, selected for short responses and low latency. MP3 output is played by `AVAudioPlayer`. The current implementation downloads each complete short utterance with character timestamps before playback, then reveals whole words against the audio playhead; it does not yet stream audio. [Model documentation](https://elevenlabs.io/docs/overview/models), [speech endpoint](https://elevenlabs.io/docs/api-reference/text-to-speech/convert-with-timestamps).

## Conversation behavior

- Tap the hand and speak. Apple Speech displays live words; OpenAI returns the final transcript when configured. Recording now waits for three seconds of continuously observed quiet after recognized words. Ongoing sound keeps it open even if recognition callbacks stall; without live words, sustained audio needs a four-second quiet tail. Tap again to finish sooner. No-speech is reported only after twelve seconds and a fresh three-second quiet stretch. Missing audio samples do not count as silence. Sixty seconds is the hard recording limit.
- After a clarification or confirmation question finishes playing, Point automatically listens for the answer. A 250 ms speaker-tail gap precedes microphone capture, then a soft haptic and Listening label mark the handoff. This follows actual ElevenLabs/system playback completion or a completed VoiceOver announcement. Cancel, typing, device setup, app inactivity and interrupted speech disarm the handoff. Silence and permission errors wait for an explicit retry; route-ready/navigation announcements do not reopen the microphone.
- Apple Maps resolves the destination and builds the route. The app speaks the destination and street only (no city, state, postcode or country) and asks you to tap Start. Ambiguous searches speak a chooser prompt.
- Navigation start, arrival, off-route detection and errors also have spoken feedback. This does not add automatic rerouting or obstacle guidance.
- A new reply replaces the old one. Starting a recording, cancelling or leaving the app cancels pending speech and stops playback. Calls/audio interruptions also cancel speech. The app does not auto-resume an old spoken reply. Point replies show the small hand avatar and reveal each word at its ElevenLabs audio timestamp. The system-voice fallback uses native speech word callbacks.
- Without ElevenLabs, or on service/network/audio failure, the system voice is used. With VoiceOver active, accessibility announcements take precedence.

OpenAI also interprets city-only requests, follow-ups, candidate selections and corrections. Point asks for a specific place in a city, confirms trips into another city and walks over 45 minutes, and accepts yes/no replies. Confirming shows route review; it never automatically starts a journey. See [conversation cases](POINT_AI_SCENARIOS.md), including future bike-mode policy.

## Validation

`swift test` covers credential parsing, HTTP requests and failures, system fallback, and stale/cancelled speech suppression without contacting either provider. The iOS target exercises audio playback through its device build; physical microphone/playback transitions still need hands-on testing.

Release builds do not load these development secrets. Distribution requires authenticated backend implementations of the speech protocols.
