# Existing algorithm integration

Point uses the existing route and geographic-beacon algorithm. The app interface, voice services, navigation lifecycle, pointing feedback, and hardware boundary are separate from that algorithm.

| Component | Retained behavior | Integration changes |
| --- | --- | --- |
| `RouteGeometry.swift` | Geographic distance and bearing helpers | Kept independent of UI and hardware |
| `PolylineDecoder.swift` | Encoded route-polyline decoding | Rejects malformed and truncated input |
| `RouteSegmenter.swift` | Step-tagged checkpoint generation | Preserves original vertices, deduplicates shared boundaries, validates input, and retains outgoing bearings |
| `TurnPointExtractor.swift` | Sparse start/turn/destination beacons | Feeds the new session and map presentation |
| `RouteModels.swift` | Checkpoint and geographic-target structure | Public route plan and narrow provider boundary |
| `App/RouteMapView.swift` | Path overlays, geographic markers, and route bounds | Native Apple Maps presentation and controls |
| `DirectionFeedback.swift` | Bearing-to-target minus heading concept | New positive glove-confirmation logic with uncertainty checks and stale-data rejection |

A beacon means a geographic navigation target, not an iBeacon transmitter.

`AppleMapsService` calls native MapKit place search and walking directions. Decoded step coordinates enter the shared `RouteSegmenter` directly, preserving the existing checkpoint and beacon logic without re-encoding geometry as JSON. Empty or one-point MapKit departure/arrival steps are accepted; a full-route polyline is the fallback when step geometry is unavailable. `LegacyDirectionsImporter` remains only for existing offline fixtures and compatibility; live navigation does not call a legacy endpoint.

Beacons remain the start, turns of at least 45 degrees, and destination. The 15-metre sampling is internal path detail, not a spacing rule for pointing targets. Removing that unnecessary sampling and improving gradual-curve selection remain follow-up work.

Route progression is independent of speech completion and motor acknowledgements. Replacement routes reset progress, while stale asynchronous route results are discarded by the controller. The hardware adapter remains responsible for producing calibrated true-north glove readings.

Only the route/map/beacon subset is carried forward. Camera, depth, AR, object detection, streaming, unrelated dashboards, account flows, and previous secrets/configuration are outside this app.

See [the project plan](PROJECT_PLAN.md) for current tuning, validation, and remaining integration work.
