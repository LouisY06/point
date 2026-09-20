import Foundation
import simd
import Testing
@testable import PointCore

struct PointingSetupSessionTests {
    let epoch = Date(timeIntervalSince1970: 10000)

    func feed(_ session: inout PointingSetupSession, up: Bool, start: Double, jitter: Double = 0) {
        for index in 0..<20 {
            let angle = (up ? Double.pi / 2 : -.pi / 2) + (index.isMultiple(of: 2) ? jitter : -jitter)
            let q = simd_quatd(angle: angle, axis: SIMD3(1, 0, 0))
            session.append(.init(quaternion: GloveQuaternion(w: q.real, x: q.imag.x, y: q.imag.y, z: q.imag.z)!,
                                 timestamp: epoch.addingTimeInterval(start + Double(index) * 0.1),
                                 health: .init(source: .bno055, calibration: 0x42, flags: 1)))
        }
    }

    func completePair(_ session: inout PointingSetupSession, device: UUID) throws {
        let downValue = session.begin(for: device, now: epoch)
        let down = try #require(downValue)
        feed(&session, up: false, start: 0)
        #expect(session.finish(down, now: epoch.addingTimeInterval(2)) == .downwardCaptured)
        let upValue = session.begin(for: device, now: epoch.addingTimeInterval(3))
        let up = try #require(upValue)
        feed(&session, up: true, start: 3)
        #expect(session.finish(up, now: epoch.addingTimeInterval(5)) == .readyToSave)
    }

    @Test func interruptionKeepsDownPoseAndRejectsLateCaptureCompletion() throws {
        let device = UUID()
        var session = PointingSetupSession()
        let downValue = session.begin(for: device, now: epoch)
        let down = try #require(downValue)
        feed(&session, up: false, start: 0)
        #expect(session.finish(down, now: epoch.addingTimeInterval(2)) == .downwardCaptured)
        let interruptedUpValue = session.begin(for: device, now: epoch.addingTimeInterval(3))
        let interruptedUp = try #require(interruptedUpValue)
        session.interrupt() // Sensor dropout, sheet dismissal or BLE disconnection.
        session.prepare(for: device, now: epoch.addingTimeInterval(10))
        #expect(session.hasDownwardPose)
        let retryUpValue = session.begin(for: device, now: epoch.addingTimeInterval(11))
        let retryUp = try #require(retryUpValue)
        feed(&session, up: true, start: 11)
        #expect(session.finish(interruptedUp, now: epoch.addingTimeInterval(13)) == nil)
        #expect(session.isCapturing)
        #expect(session.finish(retryUp, now: epoch.addingTimeInterval(13)) == .readyToSave)
        #expect(session.pendingCalibration != nil)
    }

    @Test func invalidUpwardPoseKeepsFirstPoseForRetry() throws {
        let device = UUID()
        var session = PointingSetupSession()
        let downValue = session.begin(for: device, now: epoch)
        let down = try #require(downValue)
        feed(&session, up: false, start: 0)
        #expect(session.finish(down, now: epoch.addingTimeInterval(2)) == .downwardCaptured)
        let upValue = session.begin(for: device, now: epoch.addingTimeInterval(3))
        let up = try #require(upValue)
        feed(&session, up: false, start: 3) // Same physical pose cannot complete setup.
        #expect(session.finish(up, now: epoch.addingTimeInterval(5)) == .inconsistentPoses)
        #expect(session.hasDownwardPose && session.pendingCalibration == nil)
        let retryValue = session.begin(for: device, now: epoch.addingTimeInterval(6))
        let retry = try #require(retryValue)
        feed(&session, up: true, start: 6)
        #expect(session.finish(retry, now: epoch.addingTimeInterval(8)) == .readyToSave)
    }

    @Test func unstableMeasurementNeverReportsSaved() throws {
        let device = UUID()
        var session = PointingSetupSession()
        let downValue = session.begin(for: device, now: epoch)
        let down = try #require(downValue)
        feed(&session, up: false, start: 0, jitter: .pi / 6)
        #expect(session.finish(down, now: epoch.addingTimeInterval(2)) == .unsteadyPose)
        #expect(!session.hasDownwardPose && session.pendingCalibration == nil)
    }

    @Test func differentGloveOrExpiredPairCannotReuseFirstPose() throws {
        let device = UUID()
        var session = PointingSetupSession()
        let downValue = session.begin(for: device, now: epoch)
        let down = try #require(downValue)
        feed(&session, up: false, start: 0)
        _ = session.finish(down, now: epoch.addingTimeInterval(2))
        session.prepare(for: device, now: epoch.addingTimeInterval(122))
        #expect(!session.hasDownwardPose)
        try completePair(&session, device: device)
        session.prepare(for: UUID(), now: epoch.addingTimeInterval(6))
        #expect(!session.hasDownwardPose && session.pendingCalibration == nil)
        #expect(session.finish(down, now: epoch.addingTimeInterval(6)) == nil)
    }

    @Test func failedSaveRetainsBothPosesAndRetrySurvivesRelaunch() throws {
        let suite = "PointSetupSave.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("mounts")
        try Data([0]).write(to: directory) // A file where the directory should be forces a real write failure.
        let store = PointingCalibrationStore(defaults: defaults, directory: directory)
        let device = UUID()
        var session = PointingSetupSession()
        try completePair(&session, device: device)
        #expect(session.save(to: store, for: device) == nil)
        #expect(session.pendingCalibration != nil)
        #expect(store.load(for: device) == nil)
        session.interrupt()
        session.prepare(for: device, now: epoch.addingTimeInterval(200))
        #expect(session.pendingCalibration != nil) // Completed result does not expire with the pose window.
        #expect(session.save(to: store, for: UUID()) == nil)
        try FileManager.default.removeItem(at: directory)
        let savedValue = session.save(to: store, for: device)
        let saved = try #require(savedValue)
        #expect(!session.hasDownwardPose && session.pendingCalibration == nil)
        // Even without the preferences copy, a new store reads the committed file.
        defaults.removePersistentDomain(forName: suite)
        let reopened = PointingCalibrationStore(defaults: defaults, directory: directory)
        let restored = try #require(reopened.load(for: device))
        #expect(simd_length(saved.finger - restored.finger) < 0.000001)
        #expect(reopened.onlySavedDeviceID == device)
        #expect(reopened.load(for: UUID()) == nil)
        #expect(reopened.remove(for: device))
        #expect(reopened.load(for: device) == nil && reopened.onlySavedDeviceID == nil)
    }

    @Test func existingSavedMappingMigratesWithoutRecalibration() throws {
        let suite = "PointSetupMigration.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let device = UUID()
        var session = PointingSetupSession()
        try completePair(&session, device: device)
        let oldStore = PointingCalibrationStore(defaults: defaults)
        let savedValue = session.save(to: oldStore, for: device)
        let saved = try #require(savedValue)
        let newStore = PointingCalibrationStore(defaults: defaults, directory: directory)
        #expect(newStore.load(for: device) != nil)
        defaults.removePersistentDomain(forName: suite)
        let restored = try #require(newStore.load(for: device))
        #expect(simd_length(saved.finger - restored.finger) < 0.000001)
    }
}
