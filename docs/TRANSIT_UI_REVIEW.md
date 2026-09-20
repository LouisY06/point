# Transit simulator review — September 19, 2026

Scope: the newly pulled bus/train route chooser, map panel, manual boarding/alighting, and journey transitions. Reviewed with the Impeccable native iOS audit and polish guidance. Existing home artwork, voice providers, and concurrent hardware work were preserved.

## Native-platform verdict

Pass within the reviewed phone flow: SF Symbols, semantic typography, native lists, scrolling, toggles, and labeled controls. The main violations were clipping, excessive panel height, and route rows inheriting the button tint. These were corrected. This is not a claim of completed iPad, physical-transit, or VoiceOver audio testing.

## Quality assessment

Scores describe the reviewed scope and remaining verification gaps, not a measured performance benchmark.

| Dimension | Score | Evidence / remaining gap |
| --- | --- | --- |
| Accessibility | 3/4 | Labeled actions; itinerary summaries in the accessibility tree; scalable body text; larger panel at accessibility sizes; reduced-motion sheet transition. Full VoiceOver traversal still needs a device pass. |
| Performance | 3/4 | Map geometry changes on journey phase, not each location update; native List for choices; bounded async polling. Frame timing was not profiled on hardware. |
| Appearance | 3/4 | Semantic text/surfaces, contrast-aware transit badges, clearer current-leg hierarchy. App intentionally uses the existing dark appearance. |
| Platform conformance | 3/4 | 44-point sheet handle, 48-point manual actions, safe-area spacing, independent scroll and action targets. |
| Adaptivity | 2/4 | Standard and maximum accessibility text reviewed on iPhone simulator. Tablet and landscape validation remain outside this pass. |
| **Total** | **14/20** | **Good, with device/accessibility coverage still needed.** |

## Findings and fixes

| Severity | Finding and impact | Resolution |
| --- | --- | --- |
| P1 | Arrival polling could end after a phase change while the task remained registered; vehicle updates then stopped. | Separate poll-loop identity from per-request phase tokens. Regression test exercises arrival, departure, confirmation, and lost tracking through the actual loop. |
| P1 | “I'm on board” did nothing while waiting without an identified MBTA trip. | Manual boarding enters an explicitly untracked ride, keeps the destination visible, and allows “I'm off.” |
| P1 | Alighting without GPS published the next walking event before its signal hold, briefly allowing instructions/pointing to start. | Set the hold before publishing the walking event. Regression test verifies event ordering. |
| P1 | The route panel ignored its intended maximum and could hide much of the map; collapsed instructions/actions could clip when their height changed. | New bounded sheet measures current content directly, scrolls overflow, adapts to accessibility text, and resets the header scroll position on instruction-height changes. |
| P2 | Hidden itinerary content peeked beneath the collapsed header; tap actions shared the panel-toggle gesture. | Hide collapsed details visually and from accessibility; isolate drag/tap on the handle; reserve bottom safe-area space. |
| P2 | Dense blue route paragraphs obscured boarding/alighting information. | Separate route badges, walking time, transfer count, and stop names; use semantic primary/secondary text. |
| P2 | Passed map legs did not refresh reliably, and a bus boarding marker could become a train icon after advancing. | Refresh map drawing on leg changes without resetting the camera; derive marker type from its walking leg. |
| P2 | Pre-start “Pause pointing” had no effect. | Remove this inactive action; retain active-trip controls. |

Common pattern: transit state and layout were assumed to remain constant. The revised polling and sheet both respond to changes without restarting unrelated work.

Positive findings to preserve: manual overrides, explicit tracking-loss messaging, all walking-leg beacons, route/branch filtering, separate riding and walking feedback, and GPS-dependent guidance after alighting.

## Verification

- Live simulator search from a simulated Harvard Square location to Nubian Station returned three MBTA journey choices, including Red Line / SL5 and Red Line / bus 47 alternatives.
- The debug bus fixture verified selecting a route, starting, reaching the stop, manually boarding without predictions, manually alighting into the final walking leg, and ending a trip back at voice search.
- Expanded/collapsed panels, wrapped waiting/tracking status, normal text, and maximum accessibility text were visually inspected. Accessibility-tree labels were inspected; this does not replace listening to VoiceOver.
- `swift test`: **101 tests in 23 suites passed**, including coordinator, planner, transit intent, transfer, tracking-loss, and GPS-hold coverage.
- Simulator build and unsigned iPhone build succeeded. No device installation or GitHub push was performed by this review.
- Drag/scroll automation intermittently returned `noWindowsAvailable` while the Simulator was being used concurrently. Tap expansion/collapse and action transitions were verified; continuous drag tracking needs a manual device pass.

## Repeatable review mode

Debug-only launch arguments: `--preview-transit` opens a clearly labeled, deterministic sample journey. Add `--transit-no-arrivals` to exercise manual boarding without predictions. Coordinates are public landmarks and the sample geometry is deliberately simplified. These fixtures are not used by release builds or normal launches.

Screenshots are saved locally in `output/transit-review/` (ignored by Git).

## Follow-up validation

The next meaningful check is a real bus/train journey: arrival buzz timing, foreground/background recovery, actual vehicle tracking, and GPS return after leaving a station. Also complete VoiceOver traversal and a manual drag pass. For a subsequent interface pass, use `$impeccable adapt` for tablet/landscape coverage, followed by `$impeccable polish`.
