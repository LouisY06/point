import CoreMotion
import Foundation
import PointCore

/// Keeps motion capture alive while the camera is deliberately paused. No
/// background/locked-screen claim: the demo still runs in the foreground.
@MainActor final class PocketMotionTracker {
    private let manager = CMMotionManager()
    private(set) var estimate: PocketMotionEstimator?
    private(set) var lastTimestamp: TimeInterval?
    private(set) var upwardAcceleration = 0.0
    private(set) var upwardRotation = 0.0
    private(set) var readyAt: TimeInterval?
    private(set) var failure: String?
    private var origin: (x: Double, z: Double, heading: Double, step: Double)?
    private var stillSince: TimeInterval?
    private var startedAt = 0.0
    private var generation = UUID()
    var onReady: (() -> Void)?

    var preparing: Bool { origin != nil && estimate == nil && failure == nil }
    var countdown: Int { max(0, Int(ceil((readyAt ?? ProcessInfo.processInfo.systemUptime + 8) - ProcessInfo.processInfo.systemUptime))) }
    var fresh: Bool {
        guard let lastTimestamp, estimate?.valid == true, failure == nil else { return false }
        return (0...0.3).contains(ProcessInfo.processInfo.systemUptime - lastTimestamp)
    }

    func start(x: Double, z: Double, heading: Double, stepLength: Double) {
        stop()
        guard manager.isDeviceMotionAvailable else { failure = "Motion sensing is unavailable on this phone."; return }
        origin = (x, z, heading, stepLength)
        startedAt = ProcessInfo.processInfo.systemUptime
        let generation = self.generation
        manager.deviceMotionUpdateInterval = 1.0 / 50
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] motion, error in
            // The requested operation queue is main; all demo state is main-actor owned.
            MainActor.assumeIsolated {
                guard let self, self.generation == generation else { return }
                if let error { self.failure = "Motion unavailable: \(error.localizedDescription)"; return }
                guard let motion else { return }
                self.consume(motion)
            }
        }
    }

    private func consume(_ motion: CMDeviceMotion) {
        guard failure == nil else { return }
        if let lastTimestamp, motion.timestamp <= lastTimestamp { return }
        let g = motion.gravity, a = motion.userAcceleration, r = motion.rotationRate
        guard [motion.timestamp, g.x, g.y, g.z, a.x, a.y, a.z, r.x, r.y, r.z].allSatisfy(\.isFinite) else {
            failure = "Invalid motion reading. Place the route again."; return
        }
        let norm = sqrt(g.x * g.x + g.y * g.y + g.z * g.z)
        guard norm.isFinite, norm > 0.8 else { failure = "Motion gravity reference lost. Place the route again."; return }
        upwardAcceleration = -(a.x * g.x + a.y * g.y + a.z * g.z) / norm
        upwardRotation = -(r.x * g.x + r.y * g.y + r.z * g.z) / norm
        lastTimestamp = motion.timestamp
        if readyAt == nil { readyAt = motion.timestamp + 8 }
        if estimate == nil, let origin, let readyAt {
            let still = sqrt(a.x * a.x + a.y * a.y + a.z * a.z) < 0.06
                && sqrt(r.x * r.x + r.y * r.y + r.z * r.z) < 0.20
            if !still { stillSince = nil }
            else if stillSince == nil { stillSince = motion.timestamp }
            guard motion.timestamp >= readyAt, let stillSince, motion.timestamp - stillSince >= 1 else { return }
            estimate = PocketMotionEstimator(x: origin.x, z: origin.z, heading: origin.heading,
                                             stepLength: origin.step, timestamp: motion.timestamp)
            self.origin = nil
            onReady?()
            return
        }
        estimate?.update(timestamp: motion.timestamp, upwardAcceleration: upwardAcceleration, upwardRotation: upwardRotation)
        if estimate?.valid == false { failure = "Motion readings were interrupted. Place the route again." }
    }

    func checkAvailability() {
        if estimate == nil, failure == nil, origin != nil,
           ProcessInfo.processInfo.systemUptime - (lastTimestamp ?? startedAt) > 5 {
            failure = "No motion readings. Check Motion & Fitness access in Settings."
        }
    }

    func stop() {
        generation = UUID()
        manager.stopDeviceMotionUpdates()
        estimate = nil; origin = nil; readyAt = nil; lastTimestamp = nil
        stillSince = nil; failure = nil
    }
}
