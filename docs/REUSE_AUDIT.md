# Existing algorithm integration

Point uses the existing route and geographic-beacon algorithm. The app interface, voice services, navigation lifecycle, pointing feedback, and hardware boundary are separate from that algorithm.

| Component | Retained behavior | Integration changes |
| --- | --- | --- |
| `RouteGeometry.swift` | Geographic distance and bearing helpers | Kept independent of UI and hardware |
| `PolylineDecoder.swift` | Encoded route-polyline decoding | Rejects malformed and truncated input |
| `RouteSegmenter.swift` | Step-tagged checkpoint generation | Preserves original vertices, deduplicates shared boundaries, validates input, and retains outgoing bearings |
| `TurnPointExtractor.swift` | Sparse start/turn/destination beacons | Feeds the new session and map presentation |
| `RouteModels.swift` | Checkpoint and geographic-target structure | Public route plan and narrow provider boundary |
| `App/RouteMapView.swift` | Path overlays, geographic markers, and route bounds | New map presentation, controls, and provider fallback |
| `DirectionFeedback.swift` | Bearing-to-target minus heading concept | New positive glove-confirmation logic with uncertainty checks and stale-data rejection |

A beacon means a geographic navigation target, not an iBeacon transmitter.

The Google client calls Places and Routes, then normalizes route steps for the existing algorithm. `LegacyDirectionsImporter` names that internal adapter; there is no dependency on a legacy network endpoint.

Route progression is independent of speech completion and motor acknowledgements. Replacement routes reset progress, while stale asynchronous route results are discarded by the controller. The hardware adapter remains responsible for producing calibrated true-north glove readings.

Only the route/map/beacon subset is carried forward. Camera, depth, AR, object detection, streaming, unrelated dashboards, account flows, and previous secrets/configuration are outside this app.

See [the project plan](PROJECT_PLAN.md) for current tuning, validation, and remaining integration work.
