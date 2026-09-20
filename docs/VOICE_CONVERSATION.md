# Voice interaction after the main-branch integration

The merged app preserves main's push-to-talk flow: tap the hand to open the talk panel, hold the panel while speaking, then release to send. Holding again interrupts a search or spoken reply. VoiceOver retains tap-to-start/tap-to-finish and its pause-based reply flow. Typing remains available.

Configured Deepgram transcription and speech take priority, with OpenAI transcription and the system voice as fallbacks. Destination interpretation uses the configured model and main's nearby-search and automatic transit selection behavior. Credentials remain local and are not committed.

`AudioSessionCoordinator` owns recording and speech session changes. Pocket-demo announcements acquire and release the same speaking hold, so they do not independently tear down another audio user's session. The merged recording path is main's recorder, without the earlier shared continuous-conversation engine or live playback-node detach path that caused the Send crash.

Once a walking or transit route is prepared, Point says **“Would you like to start? Say yes or no.”** After the spoken question finishes, it opens one reply window, including for users who do not enable VoiceOver. “Yes,” “start,” and “let’s go” begin the prepared route; “no” or “not yet” leave the route ready. Silence, recording failure, a cancelled question or backgrounding never starts it. The map stays visible during the reply, and the Start button, Not now button and hold-to-reply control remain available. A new destination invalidates the previous start question. Starting by button invalidates an in-flight voice reply so it cannot restart navigation. VoiceOver uses its announcement-completion event before opening the microphone.

Other continuous-conversation command/interruption helpers remain covered by unit tests but are not generally wired into this push-to-talk app flow. They must not be presented as active voice controls.

The indoor demo continues to recognize its entry command before destination search. Pocket guidance gives local spoken readiness, estimated-arrival and turn cues, including during the experimental locked-screen session. Actual speech clarity, background sensor delivery and worn-glove haptics still require device testing.

Build 19 is stored in `project.yml` for both the app and Live Activity extension and in the generated Xcode project; it no longer relies on a command-line build-number override.
