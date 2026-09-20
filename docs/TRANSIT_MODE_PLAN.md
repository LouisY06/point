# Public-transportation mode: bus/train stop beacons and multi-leg journeys

Status (September 19, 2026): implemented as described below in `Sources/PointCore/Transit/`, `App/PointViewModel.swift`, `App/PointHomeView.swift` and `App/RouteMapView.swift`, with offline tests in `Tests/PointCoreTests/TransitPlannerTests.swift` and `JourneyCoordinatorTests.swift`. On-phone verification at real stations is still pending. Two changes after the plan: there is no Walk/Transit switch — a walk over about 10 minutes triggers a spoken "take the T or a bus instead?" offer answered by yes/no or any transit/walk phrase, and "take the T to…" / "walk me to…" decide outright; and after alighting underground the next walking leg starts silent (`awaitingSignal`) and both instructions and pointing wait for a fresh, accurate GPS fix; loss and return of live MBTA data are announced once each.

## Context

Point today is walking-only: one Apple Maps walking route, turn beacons, pointing feedback to each. The user wants a second mode, **public transportation**, where a journey is walk → ride → walk, with any number of ride legs for transfers. Requirements from the user:

- Two modes: **Walking only** and **Public transportation**.
- Walking legs keep normal turn beacons. The last beacon of a walking leg sits **on the stop we board** (a new beacon kind).
- **No beacons while riding.** The vehicle's path is fixed; pointing feedback is meaningless on board. Beacons exist only at the board stop and the alight stop.
- The app watches the **MBTA API** so it knows when *our* vehicle (right route, right direction, right branch) arrives at the board stop, then fires a **distinct "vehicle arrived" buzz** (pattern defined with the firmware later). Trains come both ways, so direction matters.
- After alighting, normal walking resumes. Transfers use the same logic.
- An earlier "nearest stop + departure board" MBTA attempt was discarded in favour of this design.

User decisions: rides on **subway + buses, transfers only at rapid-transit stations**; boarding/alighting **automatic with manual override buttons**.

### Verified facts that shape the design

- **Apple can't plan transit trips** (`MKDirections` transit = ETA only). Rides are planned from MBTA data; walking legs still come from `AppleMapsService.walkingRoute` (`Sources/PointCore/AppleMapsService.swift:28`).
- **One call fetches a whole line:** `/route_patterns?filter[route]=Red,Orange,…&filter[canonical]=true&include=representative_trip.stops,representative_trip.shape&fields[stop]=name,parent_station&fields[shape]=polyline` returns every pattern with ordered platform stops (each with its parent station) and a Google-encoded shape that the existing `PolylineDecoder.decode` (`Sources/PointCore/Navigation/PolylineDecoder.swift:6`) decodes. Buses have **no canonical flag**: request their patterns without it and keep `typicality == 1`.
- **Direction/branch/arrival are observable:** `/predictions?filter[stop]=<station>&filter[route]=R&filter[direction_id]=d&include=trip,vehicle` → `prediction.attributes.stop_sequence`, `trip.relationships.route_pattern` (Ashmont vs Braintree, Green B/C/D/E), `vehicle.attributes.current_status` (`STOPPED_AT` / `INCOMING_AT` / `IN_TRANSIT_TO`) and the **platform** stop it refers to (child IDs like `70072`, never `place-…`). A prediction may exist **before a vehicle is assigned**. `/vehicles?filter[trip]=T` tracks by trip, which survives MBTA vehicle-ID reassignment.
- **Transfers/routes at stops batch:** `/routes?filter[stop]=a,b,c&filter[type]=0,1,3`.
- **Rate limit:** 20 req/min without a key, 1000 with a free key (`api-v3.mbta.com/register`). With the batching below a plan costs ~4–6 calls and polling 6/min, so the unkeyed limit works for one user; the demo should still use a key (`MBTA_API_KEY` in `.env`/`dev.env` via the existing `developmentSecret` reader in `App/PointViewModel.swift`).
- **Core constraints:** `NavigationSession.start` (`Sources/PointCore/Navigation/NavigationSession.swift:35`) requires exactly one final beacon, last; arrival needs two fixes within 8 m at ≤ 8 m accuracy (`:99–109`), which **never happens at a subway station entrance/underground**. `TurnPointExtractor.extract` always emits a final "You have arrived" beacon; `PointController.reroute` walks to `route.beacons.last`. So multi-leg logic lives **above** `PointController`: one walking `RoutePlan` per walk leg, ride/transfer legs handled by a new coordinator with its own proximity rule. `NavigationSession` and the feedback engine are untouched.

## Design

### Models

`Sources/PointCore/Navigation/RouteModels.swift`:
- `PingTarget` gains `public let kind: Kind`, `enum Kind: Equatable { turn, destination, boardStop, alightStop }`, **defaulted** (`kind: Kind = .turn`) so no existing call site changes. `RoutePlan.relabelingFinalBeacon(kind:instruction:)` (non-mutating copy) turns a walk leg's final "You have arrived" beacon into "Board the Red Line toward Alewife here".

New `Sources/PointCore/Transit/TransitModels.swift`:
- `TravelMode: String, CaseIterable { walking, transit }`.
- `TransitRoute { id, name ("Red Line"/"Route 1"), colorHex, isRapidTransit }`.
- `TransitStation { id (parent or stop id), name, coordinate, platformStopIDs: [String], wheelchairAccessible: Bool? }`.
- `RidePattern { id, routeID, directionID, headsign, stops: [(platformID, stationID, stopSequence)], shape: [CLLocationCoordinate2D] }` (what the client caches).
- `RideLeg { route, directionID, headsign, board: TransitStation, alight: TransitStation, acceptablePatternIDs: Set<String>, boardSequence: Int, alightSequence: Int, stopsRidden: Int, path: [CLLocationCoordinate2D] }`.
- `JourneyLeg: Equatable = .walk(RoutePlan) | .ride(RideLeg) | .transfer(TransitStation)`; `JourneyPlan { id, destinationName, legs, summary: String }`. Invariants: first and last legs are walks; `.transfer` sits between two rides at the same station and involves **no** `RoutePlan`.

### MBTA client (`Sources/PointCore/Transit/MBTAClient.swift`)

`protocol TransitDataSource` (so tests inject a fake) + `MBTAClient: TransitDataSource`. Injectable base URL / session / key; every method `async throws`, cancellation-checked, small `Decodable` structs, `fields[…]` on every request to shrink payloads.

- `stations(near:radiusMeters:)` — `/stops?filter[latitude]…&filter[route_type]=0,1,3&include=parent_station`, platforms collapsed to parents.
- `routes(atStops:)` — one batched `/routes?filter[stop]=…&filter[type]=0,1,3`.
- `patterns(forRoutes:)` — one batched `/route_patterns` call (canonical for rapid transit; typicality 1 for buses); **cached per route for the session, rapid-transit lines prefetched once at launch** and disk-cached 24 h.
- `arrivals(at:route:directionID:)` — `/predictions…&include=trip,vehicle&sort=arrival_time&page[limit]=6`; returns `[Arrival { tripID, patternID, stopSequence, time (arrival ?? departure), scheduleRelationship, vehicle: VehicleStatus? }]`, dropping `CANCELLED`/`SKIPPED`.
- `vehicle(forTrip:)` — `/vehicles?filter[trip]=T&include=stop` → `VehicleStatus { vehicleID, status, platformStopID, stopSequence, coordinate, updatedAt }?` (nil when unassigned).
- `alerts(routes:stations:)` — headers + `effect`, elevator closures flagged for board/alight stations.

### Planner (`Sources/PointCore/Transit/TransitPlanner.swift`)

`plan(from:to:destinationName:walking: RouteProviding, transit: TransitDataSource) async throws -> [JourneyPlan]` (best first, ≤ 3). Budget ≤ 6 MBTA calls; log the count.

1. Straight-line origin→destination < 600 m → single walk plan.
2. Origin stations: nearest ≤ 8 within 800 m (1 call). Routes at them (1 call). Patterns for those routes (1 call; rapid transit from cache).
3. **Destination candidates are computed locally**: any pattern stop within 800 m of the destination. One-ride journey = pattern where a destination stop's `stopSequence` > the origin stop's.
4. Transfers: for each pattern from step 3, each downstream **rapid-transit station** → routes there come from the cached rapid-transit patterns (0 calls) → a second pattern reaching a destination stop → two-ride journey with a `.transfer` leg (same station) or a short `.walk` leg (different station, e.g. Downtown Crossing ↔ Park St handled as a walk).
5. Score = total walking metres + 300 per transfer + 60 per stop ridden; dedupe by (route, board, alight); keep 3.
6. For the survivors: Apple walking legs (origin→board, alight→destination, and any inter-station walk), final beacons relabelled `boardStop`/`destination`; ride paths sliced from the pattern shape between the two stops' nearest vertices; `acceptablePatternIDs` = every pattern of that route/direction containing both stops. `summary` is a VoiceOver-ready sentence.

No ride found → return the walking plan and say so.

### Journey coordinator (`Sources/PointCore/Transit/JourneyCoordinator.swift`)

`@MainActor final class JourneyCoordinator: ObservableObject`, owns the unchanged `PointController` and steps through legs. Designed as a **reducer + `tick(now:)`** like `PointController.tick`, so it is testable with an injected clock and survives backgrounding (timers don't run; on scene activation the view model calls `tick` and the coordinator does one reconcile poll).

```swift
enum Phase: Equatable {
  case idle
  case walking(leg: Int)
  case waitingAtStop(leg: Int)
  case vehicleArriving(leg: Int, tripID: String)
  case riding(leg: Int, tripID: String?, confirmed: Bool, tracking: Tracking)   // nil = manual boarding without a tracked trip
  case alighting(leg: Int, tripID: String?)
  case needsReplan(reason: String)
  case arrived
}
```

Rules:
- `start(plan)` → `walking(0)` → `controller.start(walkPlan)`.
- **Reaching the board stop does not use `NavigationSession.arrived`.** The coordinator keeps its own `lastFix` (from `updateLocation`, age ≤ 30 s) and enters `waitingAtStop` when within 40 m of the board station (accuracy ≤ 50 m), or when fixes have been degraded/absent > 20 s after last being within 150 m (went underground), or on **"I'm at the stop"**. Then `controller.stop()` — pointing feedback off, no beacons.
- **Waiting:** poll `arrivals` every 10 s (a `Task` per phase; every phase change bumps a `phaseToken` and every `await` is followed by `guard token == phaseToken` — the `PointController.reroute` pattern). An arrival counts only if `patternID ∈ acceptablePatternIDs`. Buzz (`HapticCommand.vehicleArrived`) + announce when its vehicle is `INCOMING_AT` or `STOPPED_AT` one of `board.platformStopIDs`; ETA is used for the countdown text only, never for the buzz. Buzz at most once per `(tripID, board station)` (a `Set`), so INCOMING_AT → STOPPED_AT does not repeat the alert. → `vehicleArriving`.
- **Boarding (auto, tentative):** the flagged trip's vehicle goes `IN_TRANSIT_TO` with `stopSequence > boardSequence` → `riding(confirmed: false)`, announce "If you boarded, you're on the Red Line toward Alewife. Tap *Not on board* if not." Auto-revert to `waitingAtStop` if a fresh fix is still within 50 m of the station 90 s later. **I'm on board** sets `confirmed: true`; **Not on board** reverts.
- **Riding:** poll `vehicle(forTrip:)` every 10 s. Announce "Next stop is yours" when `stopSequence == alightSequence − 1` and `IN_TRANSIT_TO`. `INCOMING_AT`/`STOPPED_AT` a platform in `alight.platformStopIDs` → buzz "Get off here" → `alighting`. 3 consecutive missing vehicles → `tracking: .lost`, panel says "Live tracking lost — tap *I'm off* at <station>". Wrong-train check: when a usable fix exists and is > 500 m from the vehicle on 2 consecutive polls → `needsReplan("You may be on the wrong train")`.
- **Alighting → next leg:** **I'm off**, or (auto) the vehicle departs the alight stop while a fresh fix is within 100 m of the station. No fresh fix → stay in `alighting` and prompt. A later fix > 300 m down-line → `needsReplan("Missed your stop")`. Next leg: `.walk` → `walking(n)` + `controller.start`; `.transfer` → `waitingAtStop(n+1)` directly; none → `arrived`.
- `needsReplan` → view model re-runs the planner from `lastFix` and offers the new journey.
- `stop()` bumps the token, cancels polls, `controller.stop()`.
- Published: `phase`, `legIndex`, `countdown: (headsign, seconds?, status)?`, `alerts`, `callCount`; pass-through `feedback`/`connection`.

### Haptics

- `HapticCommand` (`Sources/PointCore/Device/GloveTransport.swift:27`) gains `case vehicleArrived`; `HapticScheduler` ignores it; `SimulatedGlove` records it. Add `public func emit(_ command: HapticCommand)` to `PointController` (same `connection == .ready && capabilities?.vibration` guard; sets `lastTransportError`) — the coordinator calls it **after** `controller.stop()` so the `.stop` sent by `resetFeedback` cannot truncate the pattern. The view model also plays `UINotificationFeedbackGenerator(.success)` on this event so the demo is felt without the glove.
- `docs/HARDWARE_INTERFACE.md`: add `vehicleArrived` — "a finite, recognisably different pattern (firmware defines, e.g. three short pulses); self-terminating like `confirm`". Remove the sentence that says there are no arrival codes.

### App wiring

- **`App/PointViewModel.swift`**: `@Published travelMode` persisted in `UserDefaults`; `journey = JourneyCoordinator(controller:)` replaces direct `controller.start/stop`; the existing 10 Hz-ish location delegate feeds `journey.updateLocation`, and `sceneInactive`/active call `journey.tick()`. After `DestinationResolver` picks a place: `travelMode == .transit` **or** `TransitPhrases.impliesTransit(text)` ("take the T/train/bus/subway to …") → run the planner → `stage = .confirmJourney`; `startJourney()` → `journey.start(plan)`; buttons map to `confirmAtStop / confirmBoarded / notOnBoard / confirmAlighted`; `cancel()` stops the journey. Walking mode path is unchanged.
- **`App/PointHomeView.swift`**: segmented **Walk / Transit** control under "Where to?" (VoiceOver-labelled); `journeySheet` listing candidates by `summary` with Confirm; route panel shows the leg list with the current leg highlighted, phase text ("Walk to Kendall/MIT", "Waiting · Alewife train in 3 min", "Arriving now — board", "Riding · 4 stops to Park St", "Get off here", "Tracking lost"), contextual buttons, and elevator/service alerts.
- **`App/RouteMapView.swift`**: takes `JourneyPlan` + `legIndex`. Walk legs as today (only the active walk leg is a pointing target); ride legs dashed in the route colour; board/alight stops with `tram.fill`/`bus.fill` from `PingTarget.kind`; passed legs muted.

### Reroute

`PointController.reroute` only runs inside a walk leg and re-walks to that leg's final beacon (board stop or destination), so it stays correct. No reroute during a ride; ride problems go through `needsReplan`.

## Files

| Action | Path |
| --- | --- |
| Delete | `Sources/PointCore/Transit/MBTAService.swift`, `…/TransitIntent.swift`, `Tests/PointCoreTests/TransitTests.swift` |
| Revert | `App/PointViewModel.swift`, `App/PointHomeView.swift`, `README.md`, `docs/PROJECT_PLAN.md` |
| Edit | `Sources/PointCore/Navigation/RouteModels.swift` (kind, relabel), `Sources/PointCore/Device/GloveTransport.swift` (vehicleArrived), `Sources/PointCore/PointController.swift` (`emit`) |
| New | `Sources/PointCore/Transit/TransitModels.swift`, `MBTAClient.swift`, `TransitPlanner.swift`, `JourneyCoordinator.swift`, `TransitPhrases.swift` |
| Edit | `App/PointViewModel.swift`, `App/PointHomeView.swift`, `App/RouteMapView.swift` |
| New tests | `Tests/PointCoreTests/TransitPlannerTests.swift` (fixture patterns: Red + Green + bus 1; one-ride, transfer, walk-only fallback, call count ≤ 6), `JourneyCoordinatorTests.swift` (fake `TransitDataSource`, scripted `now:`; full phase walk-through, tentative boarding revert, lost tracking, stale-token discard, no beacon while riding, one buzz per arrival) |
| Docs | `README.md` (modes, MBTA key), `docs/PROJECT_PLAN.md` (inventory + journey flow + not-verified list), `docs/HARDWARE_INTERFACE.md` |
| Project | `Point.xcodeproj/project.pbxproj` unchanged (new files live in the Swift package) |

## Verification

Simulator review and regression fixes are recorded in [TRANSIT_UI_REVIEW.md](TRANSIT_UI_REVIEW.md). Polling now keeps a separate loop identity and captures the phase token for each request, so an arrival or boarding transition cannot silently stop updates. Manual boarding from the waiting state works even when MBTA has not identified a trip; this displays unavailable tracking and retains the manual alighting action. The GPS hold is set before publishing the next walking-leg event after alighting.

1. `swift test` — all new tests plus the existing 26 stay green (`PingTarget.kind` default keeps them untouched).
2. `swift run point-demo` still runs.
3. Phone build with the existing `xcodebuild … DEVELOPMENT_TEAM=P4V2FY8SAS` command; install; copy `.env` (now with `MBTA_API_KEY`) to `Documents/dev.env`.
4. On the phone, Transit mode, from Kendall: "take me to Copley" → sheet offers Red Line → Park St → Green Line → Copley; confirm; walking beacon at Kendall/MIT; at the platform the panel counts down Alewife-bound trains only, buzz + announcement on arrival; tentative boarding then "I'm on board"; "Next stop is yours" before Park St; "Get off here"; transfer waits for a Green Line B/C/D/E westbound; alight at Copley; walk to the door. Repeat with a bus (Route 1 on Mass Ave). Also test: background the app mid-ride and return (reconcile), and "Not on board" after a missed train.
5. Rate-limit check: `callCount` ≤ 6 per plan, polling ≤ 6/min.

## Out of scope (stated in docs)

Commuter rail and ferry, fares, mid-ride re-planning beyond `needsReplan`, Apple multi-modal routes, any obstacle-safety claim.
