# Foreground voice conversation

Tap the hand once to start. Point uses an audible listening tone, automatically submits a turn after a 1.6-second pause in both speech and new words, and opens the next turn when spoken playback actually finishes. It keeps the microphone open during conversational replies so a recognized interruption can stop the reply without restarting input or losing the initial words. “Send now” is an optional fallback, not a required step.

## Spoken controls

- “Start”, “pause route”, and “resume route” control a prepared or active walking route.
- “First”, “second”, or “third” selects a displayed destination or transit option.
- “I’m at the stop”, “I’m on board”, “not on board”, and “I’m off” use the existing transit actions only in their applicable states.
- “Repeat that” repeats the last reply.
- “Stop listening” ends the voice conversation while leaving route guidance available. “Cancel route” cancels navigation.
- A VoiceOver magic tap invokes the voice control. Existing buttons and typing remain available.

Voice conversation is scoped to navigation and destination selection; it is not a general assistant. Indoor camera mode retains its own instructions and controls. Twelve seconds without speech ends listening with one spoken notice; a user turn is bounded at 60 seconds. Backgrounding, an audio interruption, unplugged headphones, or ending the conversation releases the microphone. It does not wake itself in the background.

## Audio and cancellation

`VoiceRecorder` uses play-and-record / voice-chat mode with AVAudioEngine voice processing. Generated speech and the rendered system-voice fallback play through that same engine's output mixer, supplying an echo-cancellation reference. The playback controller stops only its output; it does not deactivate the recorder's shared session.

Interruption requires recent sustained input activity plus recognized words, and rejects phrases that match the current assistant reply. This conservative filter can ignore an interruption that exactly repeats Point's wording. If voice processing or live recognition is unavailable, automatic turn handoff still works, but speech interruption is unavailable; the on-screen Interrupt control remains. Headphone/speaker echo behavior needs hardware testing, especially with the motor running.

Live Apple Speech text is used immediately, preferring on-device recognition where available. Configured batch transcription is used only when no live words were returned. Existing provider credentials and routing remain unchanged. Temporary capture and rendered reply files are deleted on completion/cancel. Capture is bounded to an explicit foreground conversation, including its reply periods.

Conversation replies use the app's stoppable speech player even with VoiceOver enabled. They are not duplicated as accessibility announcements, and the transcript does not force VoiceOver focus while listening or speaking. Non-conversation announcements retain the existing VoiceOver path. This requires verification with an actual screen reader user; it is not an accessibility certification.

Generation checks ignore stale synthesis, playback, and recording callbacks. Failed playback hands back to input; a 45-second response watchdog prevents indefinite waiting. Noise without recognized words cannot stop output. No late response is allowed to reopen a canceled microphone session.

## Verification

Automated checks cover interruption evidence and echo rejection, short pauses versus complete turns, context-command parsing, stale/canceled playback callbacks, and failure handoff. The iOS target is compiled separately because host Swift tests do not run microphone APIs.

On the physical iPhone, verify: interrupt a long reply with a correction; answer immediately as a reply ends; speak slowly with brief pauses; cancel during provider loading; unplug headphones; switch apps; try VoiceOver magic tap; test quiet and noisy rooms with/without haptics. Check first-word retention, no reply echo interpreted as a command, and a clear listening cue. These acoustic checks cannot be established by a simulator build.

Apple references: [voiceChat](https://developer.apple.com/documentation/avfaudio/avaudiosession/mode-swift.struct/voicechat), [AVAudioEngine voice processing](https://developer.apple.com/documentation/avfaudio/avaudioionode/setvoiceprocessingenabled(_:)).
