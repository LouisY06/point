# Point

**Point your hand, feel the way.** A haptic guiding glove that lets you find your way around a city without looking down at your phone.

---

## Inspiration

One of our teammates has Raynaud's phenomenon, which means that whenever the temperature drops even a little, the blood flow to her fingers cuts out and they stop working properly. She wears gloves for about half the year, and a phone is close to useless in gloves because you can't tap or swipe, and every time you want to check a map you have to pull a hand out into the cold. Walking somewhere unfamiliar ends up being a lot more stressful than it should be.

We started out trying to fix that one problem for her, but it didn't take long to see that it was part of something bigger. A map on a phone assumes you can see the screen, hold the phone, and spare your attention for it, and there are a lot of people for whom one or more of those things isn't true. Blind and low-vision pedestrians get around cities every day using tools that were never really built with them in mind. Cyclists are stuck choosing between watching the road and glancing at a handlebar mount. Anyone taking the bus or train has to keep checking a screen at every step to make sure the vehicle pulling in is the right one, and anyone walking with headphones in is already half distracted, so a turn-by-turn voice competing with traffic noise doesn't help much. These are very different people, but they all want the same thing, which is to get where they're going with their eyes up and their hands free.

That got us wondering what the smallest possible signal would be that could still guide someone to a destination, and we ended up with a single vibration that just means "yes, this way."

## What it does

**For the user.** You tap the glove and say where you want to go, whether that's "the closest pharmacy," "take me to Beantown," or "use public transportation to get to Bluestone Lane in Harvard Square." Point repeats the place back to you so you know it understood, works out the route, and then leaves you alone. Whenever you're not sure which way to go, you point your hand in a direction, and if that's the way to your next turn the glove buzzes. If it isn't, nothing happens, so you just sweep your hand around until you feel the pulse and walk that way. There's no screen to look at, no voice telling you to turn left or right, and no reason to take your hands out of your pockets in January.

You also never have to decide whether to walk or take transit, because Point works that out for you. If the destination is more than about a ten-minute walk, it asks out loud whether you'd like to take the T or a bus, and you answer with a yes or a no. The trip then becomes a walk, a ride, and another walk, with the boarding stop treated as a destination in its own right, so the same point-and-buzz beacons that guide you down the street also lead you to the stop. While you wait, Point follows live MBTA predictions for your particular line, direction, and branch, and a distinct four-pulse buzz tells you when your bus or train is actually arriving, rather than when the timetable claims it will. It buzzes again when it's time to get off, deals with transfers the same way, and if it notices that you've ridden past your stop, it offers to plan a new route.

**Under the hood.** The phone gets a rough idea of where you are from GPS, and Apple Maps gives us the route, which we boil down to a chain of "beacons," meaning the points along the way where you need to change direction. The one thing GPS can't tell us is which way your hand is pointing, so for that the glove carries a small 9-DOF inertial measurement unit. That's a sensor package combining an accelerometer (which way is down), a gyroscope (how fast you're turning), and a magnetometer (which way is north), and when the readings from all nine axes are fused together they give us a compass heading for the back of your hand.

This is the same idea as dead reckoning, which is how sailors navigated for centuries before satellites existed. If you know where you started, which way you're facing, and how you've moved since, you can keep track of where you are without any outside reference. GPS updates slowly and can be off by several meters, but the IMU updates a hundred times a second and never loses track of your orientation in between, so the two complement each other well. The glove sends its heading to the iPhone over Bluetooth Low Energy, the app compares it to the bearing of the next beacon, and when the two line up it sends a command back to the glove telling the motor to pulse.

One thing we were careful about is that the app never assumes anything about where your phone is. It can be in a pocket, in a bag, or on a bike mount, facing any direction, because the glove is the only thing that needs to point.

## How we built it

Everything had to fit on the back of a work glove, so we built around the smallest parts we could find. The brain is a XIAO ESP32 microcontroller, which has Bluetooth built in and is about the size of a postage stamp, and alongside it there's the 9-DOF IMU for heading, a DRV2605L haptic driver, and a coin vibration motor, all running off a small LiPo battery.

We'd originally planned on five motors so we could play different patterns across the hand, but that didn't survive contact with the hackathon. Our full set of components didn't show up until seven hours in, and coin vibration motors turned out to be the hardest thing in the building to get hold of. Once we'd finally tracked down a single motor and a single driver, we decided to build around just one and let the timing of the vibration carry the meaning instead of its position on the hand. One short pulse means you're lined up, and four pulses mean your train is here. Honestly, it ended up being a cleaner interface than the one we'd planned.

While the hardware hunt was going on, the iOS app was being built in parallel. It's written in native SwiftUI on top of a Swift package called PointCore, which holds all of the navigation logic, including route parsing, beacon generation, the pointing-alignment algorithm, a transit planner that stitches walk-ride-walk itineraries together and tracks vehicles through the MBTA API, and the protocol for talking to the glove. For speech, we use Deepgram Nova-3 to transcribe what the user says and Deepgram Flux for the spoken replies, with an OpenAI model in between working out what the user actually meant, whether that's a place name, a category like "nearest CVS," a request for transit, or a correction to something said earlier. The whole thing ships with an offline test suite that covers all of it, which is what let us keep changing things at 3 a.m. without breaking the parts that already worked.

## Individual contributions

For the first stretch, two of us were basically on a scavenger hunt, sourcing parts, wiring up the board, and getting the IMU and the haptic driver talking over separate I2C buses. In the meantime, the other two built the entire app, from the voice pipeline and the Apple Maps and MBTA integrations through to the beacon algorithm, the Bluetooth layer, and the tests.

Once the glove board was alive, the split changed. Three of us moved over to integration, which meant getting the firmware to speak the app's packet protocol, calibrating the heading against true north, and tuning the pulse timing until the buzz felt right. The fourth person designed and built the case and figured out how to mount everything on the glove so it would actually survive being worn.

## Challenges we ran into

The biggest challenge was simply time versus parts. Losing the first seven hours to missing components could easily have killed the hardware side of the project, and even once things arrived we never got the number of motors we'd designed for.

What saved us was that we refused to sit around and wait. On day one we wrote a simulated glove into the app, which is just a piece of software that produces fake headings and prints out the motor commands it would have sent. We also built a "phone mode" where the iPhone stands in for the glove using its own compass and vibration motor, which meant we could walk real routes around campus and test the alignment algorithm before a single wire had been soldered. By the time the real board came online, the app had already been navigating for hours, and integration was mostly a matter of swapping the simulated connection for the real one.

So even with fewer parts than we planned for, the finished glove does everything we set out to make it do.

## Accomplishments that we're proud of

- **Real, working integration** between a custom Bluetooth device and a native iOS app, with the phone free to sit anywhere on your body in any orientation.
- **Test beacons.** We built a camera-based tool that lets you drop virtual waypoints around a room a few meters apart, which meant we could run the full point-and-buzz loop indoors in a matter of minutes. It also made bringing up the real firmware much faster once the hardware finally arrived.
- **Transit that just works.** Point notices on its own when a trip is long enough to need the T or a bus, builds the route as walk, ride, walk, and treats the stop as just another beacon. It pulls live predictions from the MBTA API for your exact line, direction, and branch, works out when you've boarded and when you've gotten off from the vehicle tracking, buzzes at both moments, handles transfers, and offers to replan if you miss your stop.
- **A voice interface that actually works with gloves on**, all the way from "closest pharmacy" to a confirmed route in a couple of seconds.

## What we learned

Hardware takes time, and it takes it in places you don't expect. It wasn't the soldering that cost us, it was the waiting.

We also learned a lot about designing for accessibility from the beginning instead of adding it at the end. We used Devin to write an accessibility test suite and run it as continuous integration on every pull request, so any change that broke VoiceOver support got caught before it merged. Every spoken reply in the app is also delivered as a native accessibility announcement, so VoiceOver users don't end up with two voices talking over each other.

On the voice side, we spent a lot of effort finding models that were fast enough and smart enough to work out what someone means from short, messy speech. After trying several, we settled on a lightweight setup that answers in about a second, and that turns out to be the difference between something that feels like a conversation and something that feels like a chore when you're standing on a cold street corner.

## What's next for Point

Our goal for these 24 hours was deliberately narrow. We wanted to show that a handful of cheap, simple components could turn into something small enough to wear and useful enough to trust, and we think we did that. We also think it's the start of something.

Wearable tech like this gets cheaper and smaller quickly. More motors would let the glove say more than yes and no, and more sensors would let it sense the world as well as point at it, whether that's a rangefinder for curbs and obstacles, flex sensors so a gesture could pause or repeat a cue, or a way for cyclists to signal a turn without letting go of the handlebars.

Imagine walking through a Boston winter without ever taking your hands out of your gloves, or crossing a city you've never seen with your eyes on the street and your phone in your pocket, guided by nothing more than a tap on the back of your hand. That's where we want to take Point.