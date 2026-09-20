# Voice interaction after the main-branch integration

The merged app preserves main's push-to-talk flow: tap the hand to open the talk panel, hold the panel while speaking, then release to send. Holding again interrupts a search or spoken reply. VoiceOver retains tap-to-start/tap-to-finish and its pause-based reply flow. Typing remains available.

Configured Deepgram transcription and speech take priority, with the existing OpenAI, ElevenLabs and system-voice fallbacks. Destination interpretation uses the configured model and main's nearby-search and automatic transit selection behavior. Credentials remain local and are not committed.

`AudioSessionCoordinator` owns recording and speech session changes. Pocket-demo announcements acquire and release the same speaking hold, so they do not independently tear down another audio user's session. The merged recording path is main's recorder, without the earlier shared continuous-conversation engine or live playback-node detach path that caused the Send crash.

The earlier continuous-conversation command/interruption helpers remain covered by unit tests but are not wired into the current push-to-talk app flow. They must not be presented as active voice controls.

The indoor demo continues to recognize its entry command before destination search. Pocket guidance gives local spoken readiness, estimated-arrival and turn cues, including during the experimental locked-screen session. Actual speech clarity, background sensor delivery and worn-glove haptics still require device testing.
