# Point

**Point your hand, feel the way.** A haptic guiding glove that lets you navigate a city without looking down at a phone.

---

## Inspiration

One of our teammates lives with Raynaud's phenomenon. When the temperature drops even slightly, blood flow to her fingers shuts down and they stop cooperating. She spends half the year in gloves, and a phone becomes almost useless: taps don't register, swipes don't land, and every glance at a map means baring a hand to the cold. Finding her way along an unfamiliar street turns into a small ordeal.

We started sketching a solution for her and quickly realized the problem was much larger than gloves. A visual map assumes you can see it, hold a phone, and spare your attention for a screen, and that assumption leaves a lot of people out. Blind and low-vision pedestrians navigate cities every day with tools that were never designed around them. Cyclists have to choose between watching the road and watching a handlebar mount. Transit riders juggle a walk, a wait, a ride, and another walk, checking a screen at every handoff to make sure the right bus is the one pulling in. Someone walking with headphones in already has one channel occupied, and a turn-by-turn voice fighting with traffic noise rarely helps. Different people, but the same underlying need: to get where they're going with their eyes up and their hands free.

So we asked ourselves what the smallest, simplest signal that could guide someone to a destination might be. We landed on a single vibration that means *yes, this way*.

## What it does

**For the user.** Tap the glove and say where you want to go: "the closest pharmacy," "take me to Beantown," "use public transportation to get to Bluestone Lane in Harvard Square." Point confirms the place out loud, plans the route, and then gets out of the way. Whenever you're unsure, point your hand in a direction. If it's the way to your next turn, the glove buzzes; if not, it stays quiet. Sweep your hand until you feel the pulse and head that way. There's no screen to check, no voice calling out left and right, and no reason to take your hands out of your pockets in January.

You never have to pick a mode. If the destination is more than about a ten-minute walk, Point offers the T or a bus out loud, and a simple yes or no settles it. The trip becomes walk, ride, walk: the boarding stop turns into an intermediate destination, and the same point-and-buzz beacons lead you there. While you wait, Point follows live MBTA predictions for your specific line, direction, and branch, so a distinct four-pulse pattern tells you when your bus or train is actually pulling in, not when a timetable says it should. It buzzes again when it's time to get off, handles transfers the same way, and if it notices you've ridden past your stop, it offers to replan.

**Under the hood.** GPS gives the phone a rough idea of where you are, and Apple Maps supplies the route, which we reduce to a chain of "beacons": the points where you need to change direction. What GPS can't tell us is which way your hand is pointing. For that, the glove carries a 9-DOF inertial measurement unit, a tiny sensor package combining an accelerometer (which way is down), a gyroscope (how fast you're turning), and a magnetometer (which way is north). Fused together, those nine axes yield an absolute compass heading for the back of your hand.

The idea is the same one behind dead reckoning, which sailors relied on for centuries before satellites: if you know where you started, which way you're facing, and how you've moved since, you can track your position and orientation without any outside reference. GPS updates slowly and can drift by several meters; the IMU updates a hundred times a second and never loses track of orientation in between. The glove streams its heading to the iPhone over Bluetooth Low Energy, the app compares it to the bearing of the next beacon, and when the two line up it sends a pulse command back to the glove's vibration motor.

The app makes no assumptions about where your phone is. It can sit in a pocket, a bag, or a bike mount, in any orientation. The glove is the only thing that needs to point.

## How we built it

Everything had to fit on the back of a work glove, so we built around the smallest parts we could find: a XIAO ESP32 microcontroller (Bluetooth built in, about the size of a postage stamp), the 9-DOF IMU for heading, a DRV2605L haptic driver, and a coin vibration motor, all running off a small LiPo battery.

The original plan called for five motors so we could play different patterns across the hand. Reality had other ideas. Our full set of components didn't arrive until seven hours into the hackathon, and coin vibration motors turned out to be the scarcest thing in the building. When we finally tracked down a single motor and driver, we made a decision: build around one motor and let the *timing* of the vibration carry meaning instead of its position. One short pulse means you're aligned. Four pulses mean your train is here. In the end it made for a cleaner interface.

While the hardware hunt was underway, the iOS app came together in parallel. It's native SwiftUI built on a Swift package called PointCore, which holds all the navigation logic: route parsing, beacon generation, the pointing-alignment algorithm, a transit planner that stitches walk-ride-walk itineraries together and tracks vehicles through the MBTA API, and the glove protocol. Speech runs through Deepgram Nova-3 for transcription and Deepgram Flux for spoken replies, with an OpenAI model handling *intent*: whether the user is naming a place, asking for a category like "nearest CVS," requesting transit, or correcting something already said. The app ships with a full offline test suite covering all of it, which meant we could keep changing things at 3 a.m. without breaking what already worked.

## Individual contributions

For the first stretch, two of us were effectively on a scavenger hunt: sourcing parts, wiring the board, and getting the IMU and haptic driver talking over separate I2C buses. Meanwhile, the other two built the entire app, from the voice pipeline and the Apple Maps and MBTA integration to the beacon algorithm, the Bluetooth layer, and the tests.

Once the glove board came alive, the split shifted. Three of us moved onto integration: teaching the firmware the app's packet protocol, calibrating the heading against true north, and tuning pulse timing until the buzz felt right. The fourth designed and built the case and worked out how to mount everything on the glove so it would survive being worn.

## Challenges we ran into

The biggest challenge was time versus parts. Losing the first seven hours to missing components could have sunk the hardware side entirely, and even afterward we never got the number of motors we'd designed for.

What saved us was a refusal to wait. On day one we wrote a simulated glove into the app: a software stand-in that produced fake headings and printed the motor commands it would have sent. We also built a "phone mode," in which the iPhone stands in for the glove using its own compass and vibration motor, so we could walk real routes around campus and test the alignment algorithm before a single wire was soldered. By the time the real board came online, the app had been navigating for hours, and integration came down to swapping the simulated transport for the real one.

The result is a device that, despite fewer parts than planned, does everything we set out to make it do.

## Accomplishments that we're proud of

- **Real, working integration** between a custom Bluetooth device and a native iOS app, with the phone free to sit anywhere on your body in any orientation.
- **Test beacons.** We built a camera-based tool for dropping virtual waypoints around a room a few meters apart, so we could exercise the full point-and-buzz loop indoors in minutes. It made bringing up the real firmware dramatically faster once the hardware arrived.
- **Transit that just works.** Point recognizes a long trip on its own, offers the T or a bus, and builds the route as walk, ride, walk with the stop as a beacon like any other. It pulls live predictions from the MBTA API for your exact line, direction, and branch, detects boarding and alighting from vehicle tracking, buzzes at both moments, handles transfers, and offers a replan if you miss your stop.
- **A voice interface that works with gloves on**, end to end, from "closest pharmacy" to a confirmed route in a couple of seconds.

## What we learned

Hardware takes time, and it takes it in unexpected places. Not the soldering; the waiting.

We also learned a lot about designing for accessibility from the start rather than bolting it on afterward. We used Devin to write an accessibility test suite and run it as continuous integration on every pull request, so any change that broke VoiceOver support was caught before it merged. Every spoken reply in the app is also delivered as a native accessibility announcement, so VoiceOver users aren't left listening to two voices talking over each other.

On the voice side, we put real effort into finding models that were both fast and smart enough to understand intent from short, messy speech. After testing several, we settled on a lightweight configuration that answers in about a second, which is the difference between a conversation and a chore when you're standing on a cold corner.

## What's next for Point

Our goal for these 24 hours was deliberately narrow: prove that a handful of cheap, simple components could become something small enough to wear and useful enough to trust. We think we did, and we think it's the start of something.

Wearable tech like this gets cheaper and smaller quickly. More motors would let the glove say more than yes and no. More sensors could let it sense the world as well as point at it: a rangefinder for curbs and obstacles, flex sensors so a gesture could pause or repeat a cue, a way for cyclists to signal turns without letting go of the bars.

Imagine walking through a Boston winter without once taking your hands out of your gloves. Imagine crossing a city you've never seen, with your eyes on the street and your phone in your pocket, guided by nothing more than a tap on the back of your hand. That's where we want to take Point.