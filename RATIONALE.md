# Why Point

Notes on how we arrived at this idea and the reasoning behind the main choices.

## The problem we care about

Navigation itself is basically solved — phones route well, and a watch can buzz you through turns. The part that isn't solved is attention. For a pedestrian at a crossing or a biker in traffic, the moment they check the route is the moment they stop watching the road, and that's the moment that actually matters. So the goal we set was to let someone confirm their direction without looking at anything.

## Keeping the phone, but out of the way

- The phone is a good brain and a poor interface for someone who's moving. Reading it means either stopping or walking while staring at a screen.
- We kept the phone for what it's good at: GPS, routing, and holding the destination. It stays in the pocket and does the computation.
- What we wanted to replace wasn't the phone's routing, just the part where you have to look at it.

## Why not a watch

A watch was the obvious alternative, and working through why it doesn't fit is most of how we ended up here.

- It does too much. It's essentially a phone for the wrist, so a navigation buzz has to share space with messages, calls, and activity nudges that all feel about the same. The one cue we care about stops being distinct.
- Confirming a direction on it still means raising your arm and reading the screen, which is the same head-down moment we were trying to get rid of.
- A watch measures the orientation of your wrist, and people don't aim their wrist at things. We needed the input to come from something the body already does naturally.

We only need one function, and a device built around a single function can be clearer at it than a general-purpose one that happens to include it.

## The hand as the instrument

- People already point with their hands. If you ask someone for directions on the street, they gesture. Using the hand's heading as the input matches something that's already intuitive.
- That reframes the interaction: instead of the device announcing "the route is over there," you aim your hand and it tells you whether that's the right way. It's closer to asking a person than reading a map.
- Mechanically it's simple. The phone knows the bearing to the next beacon, the glove knows where the hand is pointing, and navigation is the difference between the two — confirmed by a pulse when they line up.

## Why the haptics belong on the hand

Once the input was the hand, it made sense for the feedback to be there too.

- The hand is more sensitive to touch than the wrist, so a light pulse comes through clearly without needing a strong motor.
- A buzz on the wrist is easy to miss through a sleeve, under a tight grip on handlebars, or while braking. The hand is already where the action is.
- Because the glove only ever sends one kind of signal — a confirmation that you're aligned — that signal keeps a consistent meaning instead of blending in with everything else a wrist device might do.

## Who this is for

- Pedestrians and bikers who need to keep their eyes up and their hands mostly free.
- People with visual impairments, for whom a screen was never really the right channel. The nonvisual, touch-first design isn't a separate accessibility feature layered on top — it's the same design that keeps a sighted biker's eyes on the road.

## What we deliberately left out

No camera, no depth sensing, no obstacle detection, and no dashboard of stats. Point isn't trying to be a smaller watch or a richer map. It does one thing: you say where you're going, and you feel where to point.

## Risks we're aware of

- The hand's heading depends on magnetometer calibration and is sensitive to magnetic interference. Bikes in particular are full of steel and magnets, so the reliability of the pointing signal is the main thing we still need to prove.
- Gloves are more situational for pedestrians than a watch is; the fit is most natural for biking.
- A watch is already on people's wrists, so a new object only makes sense if the eyes-up experience is clearly better rather than marginally so.
