// Uses the existing route and geographic-beacon algorithm.
// Scope and changes: docs/REUSE_AUDIT.md.
import CoreLocation
import Foundation

/// Result of merging provider step coordinates into checkpoints along the walking path.
struct RouteSegmentationResult {
    let checkpoints: [RouteCheckpoint]
    let steps: [DirectionsStepRecord]
}

enum RouteSegmentationError: Error {
    case invalidJSON
    case noRoutes
    case noLegs
    case noSteps
    case emptyPath
}

/// Merges decoded step paths and resamples into checkpoints; accepts legacy JSON fixtures too.
final class RouteSegmenter {

    private let checkpointIntervalMeters: Double

    init(checkpointIntervalMeters: Double = 15) {
        precondition(checkpointIntervalMeters.isFinite && checkpointIntervalMeters > 0)
        self.checkpointIntervalMeters = checkpointIntervalMeters
    }

    func segment(directionsResponseData data: Data) throws -> RouteSegmentationResult {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RouteSegmentationError.invalidJSON
        }
        guard let routes = json["routes"] as? [[String: Any]], let route0 = routes.first else {
            throw RouteSegmentationError.noRoutes
        }
        guard let legs = route0["legs"] as? [[String: Any]], let leg0 = legs.first else {
            throw RouteSegmentationError.noLegs
        }
        guard let stepDicts = leg0["steps"] as? [[String: Any]], !stepDicts.isEmpty else {
            throw RouteSegmentationError.noSteps
        }

        let steps = try stepDicts.map { sd -> DirectionsStepRecord in
            guard let polyObj = sd["polyline"] as? [String: Any],
                  let encoded = polyObj["points"] as? String else { throw RouteSegmentationError.emptyPath }
            let coordinates = PolylineDecoder.decode(encoded)
            guard coordinates.count >= 2 else { throw RouteSegmentationError.emptyPath }
            return DirectionsStepRecord(htmlInstructions: sd["html_instructions"] as? String ?? "",
                                        coordinates: coordinates,
                                        distanceMeters: (sd["distance"] as? [String: Any])?["value"] as? Double ?? 0)
        }
        return try segment(steps: steps)
    }

    /// Provider-neutral entry point: MapKit already supplies decoded step coordinates.
    func segment(steps: [DirectionsStepRecord]) throws -> RouteSegmentationResult {
        guard !steps.isEmpty else { throw RouteSegmentationError.noSteps }
        var tagged: [(CLLocationCoordinate2D, Int)] = []
        for (stepIndex, step) in steps.enumerated() {
            let decoded = step.coordinates
            guard decoded.allSatisfy({ CLLocationCoordinate2DIsValid($0) }) else {
                throw RouteSegmentationError.emptyPath
            }
            for p in decoded {
                if let last = tagged.last {
                    let d = RouteGeometry.distanceMeters(last.0, p)
                    if d < 1.5 {
                        tagged[tagged.count - 1] = (last.0, stepIndex)
                        continue
                    }
                }
                tagged.append((p, stepIndex))
            }
        }

        guard tagged.count >= 2 else { throw RouteSegmentationError.emptyPath }

        let resampled = resampleTaggedPath(tagged, every: checkpointIntervalMeters)
        guard resampled.count >= 2 else { throw RouteSegmentationError.emptyPath }

        var checkpoints: [RouteCheckpoint] = []
        checkpoints.reserveCapacity(resampled.count)

        let instructions = steps.map { Self.stripHTMLTags($0.htmlInstructions) }
        var cumulative: Double = 0
        for i in 0..<resampled.count {
            if i > 0 {
                cumulative += RouteGeometry.distanceMeters(resampled[i - 1].coord, resampled[i].coord)
            }
            let stepIdx = resampled[i].stepIndex
            let instruction = instructions.indices.contains(stepIdx)
                ? instructions[stepIdx]
                : ""

            let bearing: Double
            if i < resampled.count - 1 {
                bearing = RouteGeometry.bearingDegrees(from: resampled[i].coord, to: resampled[i + 1].coord)
            } else if i > 0 {
                bearing = RouteGeometry.bearingDegrees(from: resampled[i - 1].coord, to: resampled[i].coord)
            } else {
                bearing = 0
            }

            checkpoints.append(
                RouteCheckpoint(
                    coordinate: resampled[i].coord,
                    distanceFromStartMeters: cumulative,
                    stepIndex: stepIdx,
                    stepInstruction: instruction,
                    bearingToNextDegrees: bearing
                )
            )
        }

        fixStepEndBearings(checkpoints: &checkpoints, resampled: resampled)
        densifyFinalSegmentBearings(checkpoints: &checkpoints)

        return RouteSegmentationResult(checkpoints: checkpoints, steps: steps)
    }

    // MARK: - Fix #2 step-end bearings

    /// Align bearings at step boundaries with the direction into the next step’s geometry.
    private func fixStepEndBearings(
        checkpoints: inout [RouteCheckpoint],
        resampled: [(coord: CLLocationCoordinate2D, stepIndex: Int)]
    ) {
        guard checkpoints.count == resampled.count else { return }
        for i in 0..<(checkpoints.count - 1) {
            let s0 = resampled[i].stepIndex
            let s1 = resampled[i + 1].stepIndex
            if s1 > s0 {
                let b = RouteGeometry.bearingDegrees(from: checkpoints[i].coordinate, to: checkpoints[i + 1].coordinate)
                checkpoints[i] = RouteCheckpoint(
                    coordinate: checkpoints[i].coordinate,
                    distanceFromStartMeters: checkpoints[i].distanceFromStartMeters,
                    stepIndex: checkpoints[i].stepIndex,
                    stepInstruction: checkpoints[i].stepInstruction,
                    bearingToNextDegrees: b
                )
            }
        }
    }

    // MARK: - Fix #3 final-segment bearing consistency

    private func densifyFinalSegmentBearings(checkpoints: inout [RouteCheckpoint]) {
        guard checkpoints.count >= 2 else { return }
        let penultimate = checkpoints.count - 2
        let approach = RouteGeometry.bearingDegrees(
            from: checkpoints[penultimate].coordinate,
            to: checkpoints[checkpoints.count - 1].coordinate
        )
        checkpoints[penultimate] = RouteCheckpoint(
            coordinate: checkpoints[penultimate].coordinate,
            distanceFromStartMeters: checkpoints[penultimate].distanceFromStartMeters,
            stepIndex: checkpoints[penultimate].stepIndex,
            stepInstruction: checkpoints[penultimate].stepInstruction,
            bearingToNextDegrees: approach
        )
    }

    // MARK: - Resample

    /// Distance-along-route resample: emit a point every `interval` m; `stepIndex` is the segment’s start step.
    private func resampleTaggedPath(
        _ tagged: [(CLLocationCoordinate2D, Int)],
        every interval: Double
    ) -> [(coord: CLLocationCoordinate2D, stepIndex: Int)] {
        guard tagged.count >= 2 else {
            return tagged.map { ($0.0, $0.1) }
        }
        var out: [(CLLocationCoordinate2D, Int)] = []
        out.append((tagged[0].0, tagged[0].1))

        var distanceToSegmentStart: Double = 0
        var nextMark = interval

        for i in 0..<(tagged.count - 1) {
            let a = tagged[i].0
            let b = tagged[i + 1].0
            let stepIdx = tagged[i].1
            let len = RouteGeometry.distanceMeters(a, b)
            guard len > 0.001 else { continue }

            while distanceToSegmentStart + len >= nextMark - 0.001 {
                let alongSeg = nextMark - distanceToSegmentStart
                let t = min(1, max(0, alongSeg / len))
                let lat = a.latitude + (b.latitude - a.latitude) * t
                let lon = a.longitude + (b.longitude - a.longitude) * t
                out.append((CLLocationCoordinate2D(latitude: lat, longitude: lon), stepIdx))
                nextMark += interval
            }
            // Retain original corners and step boundaries as well as regular checkpoints.
            // Otherwise a turn split across two resampled chords can disappear.
            if let previous = out.last, RouteGeometry.distanceMeters(previous.0, b) < 0.1 {
                out[out.count - 1] = (b, tagged[i + 1].1)
            } else {
                out.append((b, tagged[i + 1].1))
            }
            distanceToSegmentStart += len
        }

        if let end = tagged.last {
            if let prev = out.last, RouteGeometry.distanceMeters(prev.0, end.0) > 2 {
                out.append(end)
            } else if !out.isEmpty {
                out[out.count - 1] = end
            }
        }

        return out
    }

    private static func stripHTMLTags(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
