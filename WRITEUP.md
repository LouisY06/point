# Point

**Point your hand, Feel the way.** A haptic guiding glove for everyone, so you can navigate a city without ever looking at a screen.

---

## Inspiration

One of our teammates has Raynaud's. When the temperature drops even a little, the blood flow to her fingers cuts out and they stop working properly. She lives in gloves for half the year, and a phone is nearly useless in them: you can't tap, you can't swipe, and every glance at a map means pulling a hand out into the cold. Navigating an unfamiliar street becomes genuinely stressful.

Once we started sketching a fix for her, we realized the problem was much bigger than gloves. Blind and low-vision pedestrians can't read a map at all. Cyclists shouldn't be staring at a handlebar mount. Anyone walking with headphones in is already half-distracted, and a turn-by-turn voice competing with traffic noise isn't much help. What all of these people share is a need to get where they're going with their eyes up and their hands free.

So we asked: what is the smallest, simplest signal that could guide someone to a destination? The answer we landed on is a single vibration that says *yes, that way*.

## What it does

**For the user:** You tap the glove and say where you want to go: "the closest pharmacy," "take me to Beantown," "the T to Copley." Point confirms the place out loud, plans a walking or public-transit route, and then you just walk. Whenever you're unsure, you point your hand in a direction. If that's the way to your next turn, the glove buzzes. If not, silence. Sweep your hand until it buzzes and go that way. No screen, no voice barking left and right, no hands out of your pockets in January. On the T or a bus, a distinct four-pulse buzz tells you when your train has arrived and when to get off.

**Under the hood:** The phone knows roughly *where* you are from GPS, and Apple Maps gives us the route, which we boil down into a chain of "beacons," the important points where you need to change direction. What GPS can't tell us is *which way your hand is pointing*. For that, the glove carries a 9-DOF IMU (inertial measurement unit): a tiny sensor package combining an accelerometer (which way is down), a gyroscope (how fast you're turning) and a magnetometer (which way is north). Fused together, those nine axes give an absolute compass heading for the back of your hand.

This is the same principle as **dead reckoning**, the technique sailors used for centuries before satellites: if you know your starting point, your heading, and how you've moved since, you can keep track of where you are and where you're facing without any outside reference. GPS updates slowly and can wobble by several meters; the IMU updates a hundred times a second and never loses track of your orientation in between. The glove streams that heading to the iPhone over Bluetooth Low Energy, the app compares it to the bearing of the next beacon, and when the two line up for a moment it sends a pulse command back to the glove's vibration motor.

Crucially, the app never assumes anything about where your *phone* is. It can be in a pocket, a bag, or a bike mount, in any orientation. The glove is the only thing that has to point.

## How we built it

Everything had to fit on the back of a work glove, so we built around the smallest parts we could get: a XIAO ESP32 microcontroller (Bluetooth built in, roughly the size of a postage stamp), the 9-DOF IMU for heading, a DRV2605L haptic driver, and a coin vibration motor, all powered off a small LiPo.

The plan was five motors so we could play different patterns across the hand. Reality intervened. We didn't get our full set of components until seven hours into the hackathon, and the coin vibration motors were the hardest thing in the building to find. When we finally tracked down one motor and one driver, we made the call: cut back to a single motor and make the *timing* of the vibration carry the meaning instead of its position. One short pulse means "you're aligned." A four-pulse pattern means "your train is here." It turned out to be a cleaner interface anyway.

While the hardware hunt was on, the iOS app was built in parallel. It's native SwiftUI on top of a Swift package called PointCore, which holds all the navigation logic: route parsing, beacon generation, the pointing-alignment algorithm, the transit planner (fed by live MBTA data), and the glove protocol. Speech goes through Deepgram Nova-3 for transcription and Deepgram Flux for the spoken replies, with an OpenAI model deciding *intent*: is this a place name, a category like "nearest CVS," a request for transit, or a correction to something already said? The app ships with a full offline test suite covering all of it, so we could keep changing things at 3 a.m. without breaking what already worked.

## Individual contributions

For the first stretch, two teammates were essentially on a scavenger hunt: sourcing parts, wiring the board, and getting the IMU and haptic driver talking on separate I2C buses. At the same time, the other two built the entire app: the voice pipeline, the Apple Maps and MBTA integration, the beacon algorithm, the Bluetooth layer, and the tests.

Once the glove board was alive, the split changed. Three of us moved onto integration, getting the firmware to speak the app's packet protocol, calibrating the heading against true north, and tuning pulse timing until the buzz felt right. The fourth designed and built the case and worked out how to mount everything on the glove so it would survive being worn.

## Challenges we ran into

The big one was time versus parts. Losing the first seven hours to missing components could have sunk the hardware side entirely, and even after that we never got the number of motors we'd designed for.

What saved us was refusing to wait. We wrote a simulated glove into the app on day one: a software stand-in that produced fake headings and printed the motor commands it would have sent. We also built "phone mode," where the iPhone itself acts as the glove, using its own compass and vibration motor, so we could walk real routes around campus and test the alignment algorithm before a single wire was soldered. By the time the real board came online, the app had already been navigating for hours. Integration was a matter of swapping the simulated transport for the real one.

The result: despite fewer parts than planned, the finished device does everything we set out to make it do.

## Accomplishments that we're proud of

- **Real, working integration** between a custom Bluetooth device and a native iOS app, with the phone allowed to sit anywhere on your body in any orientation. Only the glove has to point.
- **Test beacons.** We built a camera-based tool that lets you drop virtual waypoints around a room a few meters apart. It meant we could exercise the full point-and-buzz loop indoors, in minutes, and it made bringing up the real firmware dramatically faster once the hardware arrived.
- **Transit that just works.** Ask for somewhere far and Point offers the T or a bus, guides you to the stop, watches live vehicle predictions, and buzzes when it's time to board and time to get off.
- **A voice interface you can actually use with gloves on**, end to end, from "closest pharmacy" to a confirmed route in a couple of seconds.

## What we learned

Hardware takes time, and it takes it in the places you don't expect. Not the soldering, but the waiting.

We also learned a great deal about building for accessibility rather than bolting it on. We used Devin to write an accessibility test suite and run it as continuous integration on every pull request, so any change that broke VoiceOver support got caught before it merged. Every spoken reply in the app is also delivered as a native accessibility announcement, so VoiceOver users don't hear two voices talking over each other.

On the voice side, we spent real effort finding models that were both fast and smart enough to understand intent from short, messy speech: is the user naming a place, asking for a category relative to where they are, requesting public transit, or correcting a mistake? We tested several and settled on a lightweight configuration that answers in about a second, which is the difference between a conversation and a chore when you're standing on a cold corner.

## What's next for Point

Our goal for these 24 hours was narrow on purpose: prove that a handful of cheap, simple components could become something small enough to wear and useful enough to trust. We think we did that, and we think it's the start of something.

Wearable tech like this can get cheaper and smaller fast. More motors would let the glove *say* more than yes and no. More sensors (pun very much intended) could let it sense the world as well as point at it: a rangefinder for curbs and obstacles, flex sensors so a gesture could pause or repeat a cue, a way for cyclists to signal turns without letting go of the bars.

Imagine walking through a Boston winter and never once taking your hands out of your gloves. Imagine crossing a city you've never seen, with your eyes on the street and your phone in your pocket, guided by nothing more than a tap on the back of your hand. That's where we want to take Point.
