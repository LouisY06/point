# Point

**Point your hand, feel the way.** A haptic guiding glove that lets you find your way around a city without looking down at your phone.

---

## Inspiration

One of our teammates has Raynaud's phenomenon, which means that whenever the temperature drops even a little, the blood flow to her fingers cuts out and they stop working properly. She wears gloves for about half the year, and a phone is close to useless in gloves because you can't tap or swipe, and every time you want to check a map you have to pull a hand out into the cold. Walking somewhere unfamiliar ends up being a lot more stressful than it should be.

We started out trying to fix that one problem for her, but it didn't take long to see that it was part of something bigger. A map on a phone assumes you can see the screen, hold the phone, and spare your attention for it, and there are a lot of people for whom one or more of those things isn't true. Blind and low-vision pedestrians get around cities every day using tools that were never really built with them in mind. Cyclists are stuck choosing between watching the road and glancing at a handlebar mount. Anyone taking the bus or train has to keep checking a screen at every step to make sure the vehicle pulling in is the right one, and anyone walking with headphones in is already half distracted, so a turn-by-turn voice competing with traffic noise doesn't help much. These are very different people, but they all want the same thing, which is to get where they're going with their eyes up and their hands free.

That got us wondering what the smallest possible signal would be that could still guide someone to a destination, and we ended up with a single vibration that just means "yes, this way."

## What it does

**For the user.** Tap the hand, hold the panel, and say where you want to go: "the closest pharmacy," "the McDonald's on Mass Ave," or "take the T to Copley." Point works out the right place, plans the route, reads it back in a real voice, and then leaves you alone. Pocket the phone. Whenever you're not sure which way to go, point your gloved hand: if that's the way, the glove buzzes. If it isn't, nothing happens, so you sweep until you feel the pulse and walk that way. No screen, no chat window, no voice in your ear saying "turn left."

If you ask for something ambiguous, Point talks it through like a person would. "Which one, the Tatte on Boylston or on Charles?" You answer "the second one" or "the Harvard one" and it just works. If you name a place in another city, it checks before sending you on a four-hour walk.

You also never have to decide whether to walk or take transit. If the destination is more than about a ten-minute walk, Point asks out loud: *"Copley Square is about a 25 minute walk. Want to take the T or a bus instead? Say yes for transit, or no to walk."* Say "via bus" or "take the T" in the first request and it skips the question. The trip becomes a walk, a ride, and another walk, with the boarding stop treated as a destination in its own right, so the same point-and-buzz beacons that guide you down the street also lead you to the stop. While you wait, Point follows live MBTA predictions for your particular line, direction, and branch, and a distinct four-pulse buzz tells you when your bus or train is actually at the platform, not when the timetable claims it will be. It buzzes again when it's time to get off, handles transfers the same way, goes quiet underground and resumes when you surface, and if it notices you've ridden past your stop, it offers to replan.

**Under the hood.** The phone gets your position from GPS, and Apple Maps gives us the walking route, which we boil down to a chain of "beacons," the points where you need to change direction. The one thing GPS can't tell us is which way your hand is pointing, so for that the glove carries a 9-DOF inertial measurement unit: an accelerometer (which way is down), a gyroscope (how fast you're turning), and a magnetometer (which way is north), fused into a compass heading for the back of your hand.

This is the same idea as dead reckoning, which is how sailors navigated for centuries before satellites existed. GPS updates slowly and can be off by several meters, but the IMU updates a hundred times a second and never loses track of your orientation in between, so the two complement each other. The glove sends its heading to the iPhone over Bluetooth Low Energy, the app compares it to the bearing of the next beacon, and when the two line up it sends a command back to the glove telling the motor to pulse.

One thing we were careful about is that the app never assumes anything about where your phone is. It can be in a pocket, in a bag, or on a bike mount, facing any direction, because the glove is the only thing that needs to point. And the AI never invents a route: map data decides where you walk, the MBTA decides when your train is here, and the whole thing still works with no language model at all.

## How we built it

**The glove.** Everything had to fit on the back of a work glove, so we built around the smallest parts we could find. The brain is a XIAO ESP32-S3 running ESP-IDF, about the size of a postage stamp with Bluetooth built in. Beside it sit a BNO055 IMU for heading, a DRV2605L haptic driver, and a coin vibration motor, running off a small LiPo battery. The firmware runs the sensor on its own task at 50 Hz, services motor deadlines every five milliseconds, and speaks a binary BLE protocol we designed ourselves: the board and the phone negotiate capabilities in a HELLO handshake, orientation streams to the phone, and every pulse is finite and ends on the board even if Bluetooth drops mid-buzz. Codex wrote most of that integration branch, from the firmware through the protocol, the finger-axis setup, and the tests.

We'd originally planned on five motors so we could play different patterns across the hand, but that didn't survive contact with the hackathon. Our full set of components didn't show up until seven hours in, and coin vibration motors turned out to be the hardest thing in the building to get hold of. Once we'd finally tracked down a single motor and a single driver, we decided to build around just one and let the timing of the vibration carry the meaning instead of its position on the hand. One short pulse means you're lined up, and four pulses mean your train is here. Honestly, it ended up being a cleaner interface than the one we'd planned.

**The app.** While the hardware hunt was going on, the iOS app was being built in parallel. It's native SwiftUI on top of a Swift package called PointCore, which holds all of the navigation logic: route parsing, beacon generation, the pointing-alignment algorithm, a transit planner that stitches walk-ride-walk itineraries together and tracks vehicles through the MBTA API, and the glove protocol.

**Voice.** Voice is the only interface, so it had to be good. Deepgram Nova-3 transcribes what you said the moment you let go of the panel, with a keyterm list of Boston station and line names so "Kendall," "Alewife," and "Nubian" land correctly instead of turning into "Kendal" or "a life." Deepgram Flux speaks every reply (we settled on the `flux-cole-en` voice at 1.2× speed, which sounds like a friend giving directions rather than a GPS). Recording, speech, and haptics share one audio session so they never fight over the speaker, and a reply that gets cancelled by a new request never speaks late.

**Understanding.** In between, GPT-5.5 turns the transcript into strict JSON: destination, area, yes, no, cancel, or "choose this candidate." Because it's structured output against a schema, "the second one" and "yes, but the one on Main Street" resolve without any string matching on our side. We run it with reasoning off, so it answers in about a second, which is the difference between a conversation and a chore on a cold corner. We benchmarked it against GPT-4.1 and GPT-5.4 on 28 replayed requests, including corrections, ordinals, and a prompt injection; 5.5 was the only one that didn't get steered. If OpenAI is unreachable, a regex normalizer feeds plain map search and everything still works.

**Testing without hardware.** The whole thing ships with an offline test suite, 120-plus tests across the planner, the journey state machine, the resolver, and the protocol, which is what let us keep changing things at 3 a.m. without breaking the parts that already worked. Devin wrote the plan for a scenario simulation harness that replays a full walk in milliseconds with fake GPS, a fake glove, and fake speech ([PR #7](https://github.com/LouisY06/point/pull/7)), and that harness is why the glove integration could be built and exercised before the board was finished. Devin also wrote a VoiceOver accessibility audit as a UI test suite and fixed the infractions it found ([PR #9](https://github.com/LouisY06/point/pull/9)), so any change that breaks screen-reader support fails CI before it merges.

## Individual contributions

For the first stretch, two of us were basically on a scavenger hunt: sourcing parts, wiring up the board, and getting the IMU and the haptic driver talking over separate I2C buses. In the meantime, the other two built the entire app, from the voice pipeline and the Apple Maps and MBTA integrations through to the beacon algorithm, the Bluetooth layer, and the tests.

Once the glove board was alive, the split changed. Three of us moved over to integration, which meant getting the firmware to speak the app's packet protocol, calibrating the heading against true north, and tuning the pulse timing until the buzz felt right. The fourth person designed and built the case and figured out how to mount everything on the glove so it would actually survive being worn.

We leaned on AI agents for the work that would otherwise have been left undone. Codex built the glove integration branch (S3 firmware, BLE protocol, finger-axis calibration, pocket mode, tests). Devin planned the simulation harness and built the accessibility audit. Claude Code paired on the app: transit mode, push-to-talk, the Deepgram integration, the model benchmarks, and the beacon extractor rewrite.

## Challenges we ran into

The biggest challenge was simply time versus parts. Losing the first seven hours to missing components could easily have killed the hardware side of the project, and even once things arrived we never got the number of motors we'd designed for.

What saved us was that we refused to sit around and wait. On day one we wrote a simulated glove into the app, a piece of software that produces fake headings and prints out the motor commands it would have sent. We also built a "phone mode" where the iPhone stands in for the glove using its own compass and vibration motor, which meant we could walk real routes around campus and test the alignment algorithm before a single wire had been soldered. By the time the real board came online, the app had already been navigating for hours, and integration was mostly a matter of swapping the simulated connection for the real one.

The second challenge was that voice is unforgiving. Silence-based endpointing kept cutting people off mid-sentence, so we moved to push-to-talk: hold the panel, speak, let go. Then a model change quietly started passing "coffee shop near me" to the map search as literal words, and someone got routed to a coffee shop 6,000 minutes away. We fixed the model's instructions, but we also stopped trusting it: the app strips proximity words itself and refuses to route an unqualified request more than 25 km away.

Apple's routes had a subtler problem. Corners are often drawn as three or four small bends, none of them sharp enough to count as a turn, so some corners got no beacon at all. The extractor now measures heading change over a 20 m window and honours Apple's own "Turn left" labels.

So even with fewer parts than we planned for, the finished glove does everything we set out to make it do.

## Accomplishments that we're proud of

- **Real, working integration** between a custom Bluetooth device and a native iOS app, with the phone free to sit anywhere on your body in any orientation.
- **Test beacons.** A camera-based tool that lets you drop virtual waypoints around a room a few meters apart, so we could run the full point-and-buzz loop indoors in minutes. It made bringing up the real firmware much faster once the hardware finally arrived.
- **Transit that just works.** Point notices on its own when a trip is long enough to need the T or a bus, builds the route as walk, ride, walk, and treats the stop as just another beacon. It pulls live predictions from the MBTA API for your exact line, direction, and branch, works out when you've boarded and when you've gotten off from vehicle tracking, buzzes at both moments, handles transfers, goes quiet underground, and offers to replan if you miss your stop. Kendall to Copley plans in five MBTA calls and picks the fastest of three itineraries.
- **A voice interface that actually works with gloves on**, all the way from "closest pharmacy" to a spoken, confirmed route in a couple of seconds, with station names spelled right.
- **Accessibility as CI.** Every pull request runs a VoiceOver audit. Every spoken reply is also a native accessibility announcement, so screen-reader users never hear two voices at once.

## What we learned

Hardware takes time, and it takes it in places you don't expect. It wasn't the soldering that cost us, it was the waiting.

We also learned a lot about designing for accessibility from the beginning instead of adding it at the end. Having an agent write the audit and run it on every pull request meant accessibility regressions got caught the same way a failing unit test would, and that changed how we thought about every UI change.

On the voice side, we learned that the model is the least important part of a voice interface. Latency, endpointing, and what you do when the model is wrong matter more. We spent real effort finding a setup that answers in about a second, and just as much effort making sure the app never blindly trusts what the model returns.

And we learned to build the simulator first. Fake GPS, fake glove, fake speech, and a replayable walk meant the app was navigating for hours before the board existed, and every later change had a place to prove itself in milliseconds.

## What's next for Point

Our goal for these 24 hours was deliberately narrow. We wanted to show that a handful of cheap, simple components could turn into something small enough to wear and useful enough to trust, and we think we did that. We also think it's the start of something.

The nearest step is a proper study. Point is an orientation aid, not a treatment, so the right design is a crossover: blind participants walk matched routes with Point and with a voice-only app, in randomized order, measuring time to destination, wrong turns, and workload. Boston has the partners for it, and the app needs only a session logger to be ready.

Wearable tech like this gets cheaper and smaller quickly. More motors would let the glove say more than yes and no, and more sensors would let it sense the world as well as point at it, whether that's a rangefinder for curbs and obstacles, flex sensors so a gesture could pause or repeat a cue, or a way for cyclists to signal a turn without letting go of the handlebars.

Imagine walking through a Boston winter without ever taking your hands out of your gloves, or crossing a city you've never seen with your eyes on the street and your phone in your pocket, guided by nothing more than a tap on the back of your hand. That's where we want to take Point.

---

## Built with

Swift, SwiftUI, MapKit, CoreBluetooth, CoreLocation, ARKit (indoor test beacons), ESP-IDF on a XIAO ESP32-S3, BNO055, DRV2605L, Deepgram Nova-3 and Flux, OpenAI GPT-5.5 (Responses API, structured output), MBTA V3 API, Codex, Devin, Claude Code.
