# Point AI conversation cases

The app stays in the same talking card. Point's small hand avatar identifies a reply; the text matches the spoken message. No error needs an “OK” popup. A question offers Reply and typing; a route confirmation also offers explicit yes/change controls. Answering yes reveals route review, not automatic navigation.

## Walking behavior

| Situation | Point's response / behavior |
| --- | --- |
| A specific nearby place | Find the walking route; say its name and street, ending before the city. Show Start. |
| Only a city, town or broad area | “Which place in Boston would you like to go to?” Retain Boston for the next answer. Never route to an arbitrary city-center coordinate. |
| Place in another city | “Shake Shack is in Boston. Are you sure you want to walk there?” Prefer postal-city names and compare their locality/neighborhood aliases with a recent GPS-derived origin. Same-city destinations skip this question. Routes at most 1.5 km and 30 minutes also skip a city-name-only warning; mismatched neighborhood labels are not enough to interrupt a nearby walk. The over-45-minute check still applies. |
| Walking estimate exceeds 45 minutes | State the actual estimated time and ask “Are you sure you want to walk there?” Exactly 45 minutes does not trigger this rule. |
| Another city and over 45 minutes | Combine both facts into one confirmation. Avoid asking twice. |
| Multiple ambiguous results | Present locations with street names and let the user tap or name one. Reply by ordinal (“the second one”) uses only the displayed candidate IDs. Explicit “nearest” requests still prefer the nearest matching result. |
| “Yes” / “no” | Apply only to the pending route. No asks for a replacement. Yes never starts walking automatically. |
| “Yes, but the one on Main Street” | Treat as a correction, preserving the destination name; fetch and check the new route. |
| “Maybe” / “not sure” | Keep the question open; do not assume confirmation. |
| No results | Ask for a place name or street in the card. |
| No walking route / route request failure | Ask for another place. Do not substitute a driving route or claim that it is walkable. |
| No usable location | Ask for location access and a retry. Never pretend a nearby search used a valid origin. |
| “Home” / “work” without saved addresses | Ask for a place or street address; these destinations are not saved yet. |
| No speech / denied microphone | Show a spoken inline retry message with typing still available. |
| Cancel / a new destination | Cancel pending requests and replies. Discard the old route confirmation. |
| User moved while confirming | If the origin moved over 100 m or the pending route is over two minutes old, recalculate and apply checks again. |
| AI service unavailable | Use basic MapKit search and explicit yes/no handling. Map results marked as a broad area still request a specific place. Never turn an uncertain response into confirmation. |

OpenAI interprets intent, city-only requests, references and corrections. The prompt includes `currentCity` from a valid recent GPS fix, separately from the destination preference `requestedCity`; exact GPS coordinates are not sent in the intent prompt. Reverse geocoding is shared between interpretation and review only for 30 seconds and within 100 metres of the lookup fix. Unknown current city is omitted, never assumed to differ from the destination. Swift decides whether route confirmation is required using map-provided city and walking time. Neither the language model nor the voice service invents an ETA or starts a journey. The current city comparison cannot detect another city when reverse geocoding returns no locality; the duration check still applies. Handle that uncertainty explicitly before a wider release.

## Future bike mode

Bike mode is planned, not offered by this build. Keep it a separate routing mode with its own policy rather than reusing walking geometry or the 45-minute rule.

| Situation | Proposed bike behavior |
| --- | --- |
| City-only / ambiguous place | Same clarification flow before starting the ride. |
| Different city | Mention the destination city. Confirm before navigation; adjacent city boundaries alone are common on bike trips. Tune this policy separately from walking. |
| Long trip | Confirm using cycling ETA, distance and elevation where available. The warning threshold is not chosen yet; 45 walking minutes must not be reused implicitly. |
| No cycling route from the provider | Explain that a bike route is unavailable. Offer an explicit mode change; never label a walking or driving route as cycling. |
| Stairs, ferry, restricted access or dismount section | Use provider-supplied restrictions and ask before starting when material. Do not infer bike suitability from the language model or a walking route. |
| User is already riding when clarification is needed | Give one short spoken message, retain the current route, and defer complex choices until the user can stop. Avoid attention-demanding cards while moving. |
| Wind and traffic noise | Tune endpoint detection for the mode; allow repeat and glove-triggered push-to-talk. Do not lower the timeout enough to cut off hesitant speech. |
| Phone locked or Bluetooth/headphones interrupted | Preserve route state and expose clear audio availability. Real background voice and interruption behavior must be validated before shipping bike mode. |
| Switching walk ↔ bike during a trip | Recalculate with the new transport mode, restate ETA and obtain any required confirmation. Never silently retain the previous route. |
| Off-route or unsafe-to-follow instruction | Use the route provider to recalculate. Glove alignment is directional feedback and cannot assess road crossings, obstacles or cycling access. |

Still to design: how users choose a travel mode, the bike duration/distance/elevation thresholds, saved home/work locations, provider support for cycling, and voice interaction while moving. No provider operating hours, road restrictions or accessibility guarantees should be spoken without supporting data.
