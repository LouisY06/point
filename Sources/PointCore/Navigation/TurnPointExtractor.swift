// Uses the existing route and geographic-beacon algorithm.
// Scope and changes: docs/REUSE_AUDIT.md.
import CoreLocation
import Foundation

/// Picks sparse ping targets from dense checkpoints.
///
/// A corner is a change of heading over a short stretch of path, not between two adjacent
/// checkpoints: map geometry rounds many corners into several small bends of 20–30° each, and the
/// old adjacent-only test (45°) drew nothing there. Heading is now compared over `windowMeters`
/// before and after each checkpoint, the beacon lands on the sharpest checkpoint of the bend, and
/// a provider maneuver ("Turn left onto …") counts even when the geometry is gentle.
final class TurnPointExtractor {
    private let turnThresholdDegrees: Double
    private let maneuverThresholdDegrees: Double
    private let windowMeters: Double
    private let spacingMeters: Double

    init(turnThresholdDegrees: Double = 40, maneuverThresholdDegrees: Double = 20,
         windowMeters: Double = 20, spacingMeters: Double = 20) {
        self.turnThresholdDegrees = turnThresholdDegrees
        self.maneuverThresholdDegrees = maneuverThresholdDegrees
        self.windowMeters = windowMeters
        self.spacingMeters = spacingMeters
    }

    func extract(checkpoints: [RouteCheckpoint]) -> [PingTarget] {
        guard let first = checkpoints.first else { return [] }
        if checkpoints.count == 1 {
            return [PingTarget(coordinate: first.coordinate,
                               instruction: first.stepInstruction.isEmpty ? "You have arrived" : first.stepInstruction,
                               isFinalDestination: true, bearingAfterTurnDegrees: first.bearingToNextDegrees)]
        }
        let lastIndex = checkpoints.count - 1
        let last = checkpoints[lastIndex]

        struct Candidate { let index: Int; let sharpness: Double; let bend: Double; let bearingOut: Double }
        var candidates: [Candidate] = []
        for i in 1..<lastIndex {
            let here = checkpoints[i]
            // Heading over a window each side; falls back to the neighbours near the route ends.
            var back = i - 1
            while back > 0, here.distanceFromStartMeters - checkpoints[back].distanceFromStartMeters < windowMeters { back -= 1 }
            var ahead = i + 1
            while ahead < lastIndex, checkpoints[ahead].distanceFromStartMeters - here.distanceFromStartMeters < windowMeters { ahead += 1 }
            let windowedIn = RouteGeometry.bearingDegrees(from: checkpoints[back].coordinate, to: here.coordinate)
            let windowedOut = RouteGeometry.bearingDegrees(from: here.coordinate, to: checkpoints[ahead].coordinate)
            let bend = RouteGeometry.angleDifferenceDegrees(windowedIn, windowedOut)
            let adjacentIn = RouteGeometry.bearingDegrees(from: checkpoints[i - 1].coordinate, to: here.coordinate)
            let adjacentOut = RouteGeometry.bearingDegrees(from: here.coordinate, to: checkpoints[i + 1].coordinate)
            let sharpness = RouteGeometry.angleDifferenceDegrees(adjacentIn, adjacentOut)
            let maneuver = here.stepIndex != checkpoints[i - 1].stepIndex && Self.describesTurn(here.stepInstruction)
            let isTurn = max(bend, sharpness) >= turnThresholdDegrees || (maneuver && max(bend, sharpness) >= maneuverThresholdDegrees)
            guard isTurn else { continue }
            // A maneuver checkpoint outranks plain geometry so the beacon sits where the instruction applies.
            candidates.append(Candidate(index: i, sharpness: sharpness + (maneuver ? 360 : 0), bend: bend, bearingOut: adjacentOut))
        }

        // One beacon per bend: keep the sharpest checkpoint, drop others within `spacingMeters` of
        // it or of the route ends, which already carry beacons.
        var chosen: [Candidate] = []
        var occupied: [Double] = [first.distanceFromStartMeters, last.distanceFromStartMeters]
        for candidate in candidates.sorted(by: { ($0.sharpness, $0.bend, -$0.index) > ($1.sharpness, $1.bend, -$1.index) }) {
            let along = checkpoints[candidate.index].distanceFromStartMeters
            guard occupied.allSatisfy({ abs($0 - along) >= spacingMeters }) else { continue }
            occupied.append(along)
            chosen.append(candidate)
        }

        var targets: [PingTarget] = [
            PingTarget(coordinate: first.coordinate,
                       instruction: first.stepInstruction.isEmpty ? "Begin route" : first.stepInstruction,
                       isFinalDestination: false, bearingAfterTurnDegrees: first.bearingToNextDegrees)
        ]
        for candidate in chosen.sorted(by: { $0.index < $1.index }) {
            let checkpoint = checkpoints[candidate.index]
            targets.append(PingTarget(coordinate: checkpoint.coordinate,
                                      instruction: checkpoint.stepInstruction.isEmpty ? "Turn" : checkpoint.stepInstruction,
                                      isFinalDestination: false, bearingAfterTurnDegrees: candidate.bearingOut))
        }
        targets.append(PingTarget(coordinate: last.coordinate, instruction: "You have arrived",
                                  isFinalDestination: true, bearingAfterTurnDegrees: last.bearingToNextDegrees))
        return targets
    }

    /// Provider wording for a maneuver, as opposed to "Continue on …" or "Walk to …".
    static func describesTurn(_ instruction: String) -> Bool {
        instruction.range(of: #"(?i)\b(?:turn|left|right|bear|keep|sharp|u-turn|around)\b"#, options: .regularExpression) != nil
    }
}
