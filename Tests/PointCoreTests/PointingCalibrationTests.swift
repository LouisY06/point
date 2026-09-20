import Foundation
import simd
import Testing
@testable import PointCore

// System=1, gyro=3, accelerometer=0, magnetometer=2 is sufficient.
private let healthy = FirmwareSensorHealth(source: .bno055, calibration: 0x72, flags: 1)
private let epoch = Date(timeIntervalSince1970: 10000)
private func quaternion(_ q: simd_quatd) -> GloveQuaternion {
    GloveQuaternion(w: q.real, x: q.imag.x, y: q.imag.y, z: q.imag.z)!
}
private func samples(_ q: simd_quatd, start: Double, jitter: Double = 0) -> [GloveOrientationSample] {
    (0..<18).map { i in
        let time = epoch.addingTimeInterval(start + Double(i) * 0.1)
        let variation = simd_quatd(angle: (i % 2 == 0 ? jitter : -jitter) * .pi / 180, axis: SIMD3(1, 0, 0))
        return .init(quaternion: quaternion(variation * q), timestamp: time, health: healthy)
    }
}
private func calibration(mount: simd_quatd = simd_quatd(angle: 0, axis: SIMD3(0, 0, 1))) throws -> PointingCalibration {
    let down = simd_quatd(angle: -.pi / 2, axis: SIMD3(1, 0, 0)) * mount
    let up = simd_quatd(angle: .pi / 2, axis: SIMD3(1, 0, 0)) * mount
    let a = try #require(PointingCalibration.capture(samples(down, start: 0), direction: .down, now: epoch.addingTimeInterval(1.8)))
    let b = try #require(PointingCalibration.capture(samples(up, start: 3), direction: .up, now: epoch.addingTimeInterval(4.8)))
    return try #require(PointingCalibration(first: a, second: b))
}

struct PointingCalibrationTests {
    @Test func relativeReferenceAbsorbsNorthTransitionButKeepsSubsequentTurns() {
        var reference = RelativeOrientationReference()
        let initial = GloveOrientationSample(quaternion: quaternion(simd_quatd(angle: 0, axis: SIMD3(0, 0, 1))),
                                             timestamp: epoch, health: .init(source: .bno055, calibration: 0x30, flags: 1))
        let settled = GloveOrientationSample(quaternion: quaternion(simd_quatd(angle: -.pi / 3, axis: SIMD3(0, 0, 1))),
                                             timestamp: epoch.addingTimeInterval(0.1), health: healthy)
        reference.update(previous: initial, current: settled)
        let corrected = reference.apply(to: .init(degrees: 60, accuracyDegrees: 5, timestamp: settled.timestamp, reference: .relative))
        #expect(abs(DirectionFeedbackEngine.signedAngle(corrected.degrees)) < 0.001)
        let turned = GloveOrientationSample(quaternion: quaternion(simd_quatd(angle: -.pi / 2, axis: SIMD3(0, 0, 1))),
                                            timestamp: epoch.addingTimeInterval(0.2), health: healthy)
        reference.update(previous: settled, current: turned)
        #expect(abs(reference.apply(to: .init(degrees: 90, accuracyDegrees: 5, timestamp: turned.timestamp, reference: .relative)).degrees - 30) < 0.001)
        #expect(reference.adjustments == 1)
    }


    @Test func briefCameraMotionKeepsRoomReferenceButLongLossAndRelocalizationDoNot() {
        var continuity = RoomTrackingContinuity()
        func check(normal: Bool, mayKeepReference: Bool, now: TimeInterval) -> Bool {
            continuity.requiresRealignment(normal: normal, mayKeepReference: mayKeepReference, now: now)
        }
        #expect(!check(normal: true, mayKeepReference: true, now: 0))
        #expect(!check(normal: false, mayKeepReference: true, now: 1))
        #expect(!check(normal: true, mayKeepReference: true, now: 1.4))
        #expect(!check(normal: false, mayKeepReference: true, now: 2))
        #expect(check(normal: false, mayKeepReference: true, now: 3.1))
        #expect(check(normal: true, mayKeepReference: true, now: 3.2))
        #expect(check(normal: false, mayKeepReference: false, now: 4))
        _ = continuity.requiresRealignment(normal: true, mayKeepReference: true, now: 4.1)
        _ = continuity.requiresRealignment(normal: false, mayKeepReference: true, now: 5)
        // Recovery must still detect a long gap even if no intermediate tick ran.
        #expect(check(normal: true, mayKeepReference: true, now: 7))
    }
    @Test func relativeDemoAcceptsUnsettledCompassButKeepsHealthFreshnessAndElevation() throws {
        let mount = try calibration()
        let unsettled = FirmwareSensorHealth(source: .bno055, calibration: 0x30, flags: 1)
        let sample = GloveOrientationSample(quaternion: quaternion(simd_quatd(angle: 0, axis: SIMD3(1, 0, 0))), timestamp: epoch, health: unsettled)
        #expect(mount.magneticHeading(sample, now: epoch) == nil)
        #expect(mount.relativeHeading(sample, now: epoch)?.reference == .relative)
        #expect(mount.relativeHeading(sample, now: epoch.addingTimeInterval(0.51)) == nil)
        for angle in [-Double.pi / 2, Double.pi / 2] {
            let down = GloveOrientationSample(quaternion: quaternion(simd_quatd(angle: angle, axis: SIMD3(1, 0, 0))), timestamp: epoch, health: unsettled)
            #expect(mount.relativeHeading(down, now: epoch) == nil)
        }
        for levels: UInt8 in [0, 0x20] {
            #expect(mount.relativeHeading(.init(quaternion: sample.quaternion, timestamp: epoch,
                health: .init(source: .bno055, calibration: levels, flags: 1)), now: epoch) == nil)
        }
    }
    @Test func savedMountSurvivesStoreRecreationAndStaysSpecificToOneGlove() throws {
        let suite = "PointMountTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let device = UUID(), other = UUID()
        let original = try calibration(mount: simd_quatd(angle: 0.72, axis: simd_normalize(SIMD3(1, 2, 3))))
        PointingCalibrationStore(defaults: defaults).save(original, for: device)
        let reopened = PointingCalibrationStore(defaults: try #require(UserDefaults(suiteName: suite)))
        #expect(reopened.onlySavedDeviceID == device)
        reopened.save(original, for: other)
        #expect(reopened.onlySavedDeviceID == nil)
        reopened.remove(for: other)
        let restored = try #require(reopened.load(for: device))
        #expect(simd_length(restored.finger - original.finger) < 0.000001)
        #expect(restored.uncertainty == original.uncertainty)
        #expect(reopened.load(for: other) == nil)
        reopened.remove(for: device)
        #expect(PointingCalibrationStore(defaults: defaults).load(for: device) == nil)
    }

    @Test func persistedMappingRejectsInvalidOrUnsupportedData() throws {
        for json in [
            #"{"version":2,"finger":[0,1,0],"uncertainty":5,"validationError":0}"#,
            #"{"version":1,"finger":[0,0,0],"uncertainty":5,"validationError":0}"#,
            #"{"version":1,"finger":[0,1],"uncertainty":5,"validationError":0}"#,
            #"{"version":1,"finger":[0,1,0],"uncertainty":2,"validationError":0}"#,
            #"{"version":1,"finger":[0,1,0],"uncertainty":5,"validationError":12}"#,
            "invalid"
        ] {
            #expect((try? JSONDecoder().decode(PointingCalibration.self, from: Data(json.utf8))) == nil)
        }
    }

    @Test func noSixFaceCalibrationButGyroCompassAndNorthStillRequired() {
        for system: UInt8 in 1...3 {
            for accel: UInt8 in 0...3 {
                for mag: UInt8 in 2...3 {
                    let levels = system << 6 | 3 << 4 | accel << 2 | mag
                    #expect(FirmwareSensorHealth(source: .bno055, calibration: levels, flags: 1).fusionBlockingReason == nil)
                }
            }
        }
        for levels: UInt8 in [0x32, 0x33, 0x62, 0x71, 0x70] {
            #expect(FirmwareSensorHealth(source: .bno055, calibration: levels, flags: 1).fusionBlockingReason != nil)
        }
    }

    @Test func screenshotCalibrationLevelsAllowBothPosesBeforeNorthIsFound() throws {
        let screenshotHealth = FirmwareSensorHealth(source: .bno055, calibration: 0x3D, flags: 1)
        #expect(screenshotHealth.system == 0 && screenshotHealth.gyro == 3 && screenshotHealth.magnetometer == 1)
        #expect(screenshotHealth.mountingBlockingReason == nil)
        #expect(screenshotHealth.fusionBlockingReason != nil)
        func window(_ angle: Double, start: Double) -> [GloveOrientationSample] {
            samples(simd_quatd(angle: angle, axis: SIMD3(1, 0, 0)), start: start).map {
                .init(quaternion: $0.quaternion, timestamp: $0.timestamp, health: screenshotHealth)
            }
        }
        let down = try #require(PointingCalibration.capture(window(-.pi / 2, start: 0), direction: .down, now: epoch.addingTimeInterval(1.8)))
        let up = try #require(PointingCalibration.capture(window(.pi / 2, start: 3), direction: .up, now: epoch.addingTimeInterval(4.8)))
        let mount = try #require(PointingCalibration(first: down, second: up))
        let identity = quaternion(simd_quatd(angle: 0, axis: SIMD3(0, 0, 1)))
        #expect(mount.magneticHeading(.init(quaternion: identity, timestamp: epoch, health: screenshotHealth), now: epoch) == nil)
        #expect(mount.magneticHeading(.init(quaternion: identity, timestamp: epoch, health: healthy), now: epoch) != nil)
    }

    @Test func fullyCalibratedFusionSurvivesIndividualGyroOffsetCalibrationChanges() throws {
        let mount = try calibration()
        for gyro: UInt8 in 0...3 {
            let health = FirmwareSensorHealth(source: .bno055, calibration: 0xCF | gyro << 4, flags: 1)
            #expect(health.system == 3 && health.gyro == gyro && health.magnetometer == 3)
            #expect(health.mountingBlockingReason == nil && health.fusionBlockingReason == nil)
            for heading in [0.0, 45, 180, 350] {
                let q = quaternion(simd_quatd(angle: -heading * .pi / 180, axis: SIMD3(0, 0, 1)))
                let sample = GloveOrientationSample(quaternion: q, timestamp: epoch, health: health)
                let reading = try #require(mount.magneticHeading(sample, now: epoch))
                #expect(abs(DirectionFeedbackEngine.signedAngle(reading.degrees - heading)) < 0.001)
                #expect(mount.magneticHeading(sample, now: epoch.addingTimeInterval(0.51)) == nil)
            }
            let lowered = GloveOrientationSample(quaternion: quaternion(simd_quatd(angle: -.pi / 2, axis: SIMD3(1, 0, 0))),
                                                timestamp: epoch, health: health)
            #expect(mount.magneticHeading(lowered, now: epoch) == nil)
        }
        // Full system calibration does not override compass loss or hardware faults.
        for health in [
            FirmwareSensorHealth(source: .bno055, calibration: 0x8F, flags: 1),
            FirmwareSensorHealth(source: .bno055, calibration: 0xCD, flags: 1),
            FirmwareSensorHealth(source: .bno055, calibration: 0xCF, flags: 0),
            FirmwareSensorHealth(source: .bno055, calibration: 0xCF, flags: 5),
            FirmwareSensorHealth(source: .mpu6050, calibration: 0xCF, flags: 9)
        ] {
            #expect(health.fusionBlockingReason != nil)
        }
    }

    @Test func gyroSubscoreChangeDoesNotInventARReferenceShift() {
        var reference = RelativeOrientationReference()
        let before = GloveOrientationSample(quaternion: quaternion(simd_quatd(angle: 0, axis: SIMD3(0, 0, 1))),
                                           timestamp: epoch, health: .init(source: .bno055, calibration: 0xFF, flags: 1))
        let after = GloveOrientationSample(quaternion: quaternion(simd_quatd(angle: -.pi / 6, axis: SIMD3(0, 0, 1))),
                                          timestamp: epoch.addingTimeInterval(0.1), health: .init(source: .bno055, calibration: 0xCF, flags: 1))
        reference.update(previous: before, current: after)
        #expect(reference.adjustments == 0)
        #expect(reference.apply(to: .init(degrees: 30, accuracyDegrees: 5, timestamp: after.timestamp, reference: .relative)).degrees == 30)
    }

    @Test func opposingGravityPosesLearnArbitraryMountWithoutPhoneReference() throws {
        let mount = simd_quatd(angle: 0.72, axis: simd_normalize(SIMD3(1, 2, 3)))
        let result = try calibration(mount: mount)
        #expect(simd_length(result.finger - mount.inverse.act(SIMD3(0, 1, 0))) < 0.001)
        let q = simd_quatd(angle: 10 * .pi / 180, axis: SIMD3(0, 0, 1)) * mount
        let reading = try #require(result.magneticHeading(.init(quaternion: quaternion(q), timestamp: epoch, health: healthy), now: epoch))
        #expect(abs(reading.degrees - 350) < 0.001)
        #expect(result.validationError < 0.001)
    }

    @Test func wristRollDoesNotChangeFingerDirection() throws {
        let mount = try calibration()
        for roll in [-170.0, -80, 0, 95, 175] {
            let yaw = simd_quatd(angle: -.pi / 2, axis: SIMD3(0, 0, 1))
            let q = yaw * simd_quatd(angle: roll * .pi / 180, axis: SIMD3(0, 1, 0))
            let reading = try #require(mount.magneticHeading(.init(quaternion: quaternion(q), timestamp: epoch, health: healthy), now: epoch))
            #expect(abs(reading.degrees - 90) < 0.001)
        }
    }

    @Test func loweredVerticalAndRaisedTooHighAreSilent() throws {
        let mount = try calibration()
        for pitch in [-90.0, -60, -31, 31, 60, 90] {
            let q = simd_quatd(angle: pitch * .pi / 180, axis: SIMD3(1, 0, 0))
            #expect(mount.magneticHeading(.init(quaternion: quaternion(q), timestamp: epoch, health: healthy), now: epoch) == nil)
        }
        for pitch in [-29.0, 0, 29] {
            let q = simd_quatd(angle: pitch * .pi / 180, axis: SIMD3(1, 0, 0))
            #expect(mount.magneticHeading(.init(quaternion: quaternion(q), timestamp: epoch, health: healthy), now: epoch) != nil)
        }
    }

    @Test func samePoseWrongOrderAndPoorOppositionFail() throws {
        let down = simd_quatd(angle: -.pi / 2, axis: SIMD3(1, 0, 0))
        let first = try #require(PointingCalibration.capture(samples(down, start: 0), direction: .down, now: epoch.addingTimeInterval(1.8)))
        for angle in [-90.0, 0, 70] {
            let q = simd_quatd(angle: angle * .pi / 180, axis: SIMD3(1, 0, 0))
            let second = try #require(PointingCalibration.capture(samples(q, start: 3), direction: .up, now: epoch.addingTimeInterval(4.8)))
            #expect(PointingCalibration(first: first, second: second) == nil)
        }
        let repeated = try #require(PointingCalibration.capture(samples(down, start: 3), direction: .down, now: epoch.addingTimeInterval(4.8)))
        #expect(PointingCalibration(first: first, second: repeated) == nil)
        #expect(PointingCalibration(first: repeated, second: first) == nil)
    }

    @Test func movementSparseDuplicateAndOldSamplesFail() {
        let down = simd_quatd(angle: -.pi / 2, axis: SIMD3(1, 0, 0))
        let data = samples(down, start: 0)
        #expect(PointingCalibration.capture(samples(down, start: 0, jitter: 10), direction: .down, now: epoch.addingTimeInterval(1.8)) == nil)
        #expect(PointingCalibration.capture(data, direction: .down, now: epoch.addingTimeInterval(3)) == nil)
        #expect(PointingCalibration.capture(Array(data.prefix(8)), direction: .down, now: epoch.addingTimeInterval(0.8)) == nil)
        var duplicated = data; duplicated[8] = data[7]
        #expect(PointingCalibration.capture(duplicated, direction: .down, now: epoch.addingTimeInterval(1.8)) == nil)
    }

    @Test func staleSamplesCalibrationLossAndQuaternionCorruptionFail() throws {
        let mount = try calibration()
        let identity = quaternion(simd_quatd(angle: 0, axis: SIMD3(0, 0, 1)))
        let sample = GloveOrientationSample(quaternion: identity, timestamp: epoch, health: healthy)
        #expect(mount.magneticHeading(sample, now: epoch.addingTimeInterval(0.51)) == nil)
        #expect(mount.magneticHeading(sample, now: epoch.addingTimeInterval(-0.01)) == nil)
        for (source, cal, flags): (FirmwareSensorHealth.Source, UInt8, UInt8) in [(.bno055, 253, 1), (.bno055, 255, 0), (.bno055, 255, 5), (.mpu6050, 255, 9)] {
            #expect(mount.magneticHeading(.init(quaternion: identity, timestamp: epoch,
                health: .init(source: source, calibration: cal, flags: flags)), now: epoch) == nil)
        }
        #expect(GloveQuaternion(w: 0, x: 0, y: 0, z: 0) == nil)
        #expect(GloveQuaternion(w: .nan, x: 0, y: 0, z: 0) == nil)
        #expect(GloveQuaternion(w: 2, x: 0, y: 0, z: 0) == nil)
    }

    @Test func roomReferenceConnectsARAxesToGloveWithoutCameraYaw() throws {
        let room = try #require(RoomGloveAlignment(targetX: 0, targetZ: -2, magneticHeading: 350))
        #expect(abs(room.error(targetX: 2, targetZ: 0, magneticHeading: 80)!) < 0.001)
        #expect(abs(room.error(targetX: -2, targetZ: 0, magneticHeading: 260)!) < 0.001)
        #expect(RoomGloveAlignment(targetX: 0, targetZ: -0.5, magneticHeading: 0) == nil)
        #expect(room.error(targetX: .nan, targetZ: 0, magneticHeading: 0) == nil)
    }

    @Test func gradedPulsesAreBoundedAndLossStopsImmediately() {
        var feedback = GlovePulseFeedback()
        let first = feedback.update(error: 0, now: epoch)
        if case .confirm(let duration, let intensity) = first { #expect(duration <= 180 && intensity <= 204) }
        else { Issue.record("Expected a finite pulse") }
        #expect(feedback.update(error: 0, now: epoch.addingTimeInterval(0.1)) == nil)
        #expect(feedback.update(error: 36, now: epoch.addingTimeInterval(0.15)) == .stop)
        #expect(feedback.intensity == 0)
        #expect(feedback.stop() == nil)
    }
}

@MainActor struct QuaternionTransportTests {
    @Test func liveFullyCalibratedSystemKeepsOrientationAndHapticsThroughGyroSubscoreDrop() throws {
        let glove = FirmwareGlove()
        var packets: [Data] = []
        glove.write = { packets.append($0) }
        func respond(_ payload: [UInt8], at seconds: Double) {
            var header = Array(packets.last!.prefix(7)); header[2] |= 0x80
            glove.receive(Data(header + payload), now: epoch.addingTimeInterval(seconds))
        }
        func poll(_ levels: UInt8, at seconds: Double) {
            glove.tick(now: epoch.addingTimeInterval(seconds))
            #expect(packets.last?[2] == 5)
            respond([0, 64, 0, 0, 0, 0, 0, 0, 0, 0, 1, levels, 1], at: seconds + 0.01)
        }
        glove.beginLink(now: epoch)
        respond([31], at: 0.01)
        respond([0], at: 0.02)
        let saved = try calibration()
        glove.calibrate(saved)
        glove.northCorrection = MagneticNorthCorrection(trueHeading: 5, magneticHeading: 0, accuracy: 5, timestamp: epoch)
        poll(0xFF, at: 0.1)
        let northReferenceID = glove.calibrationID
        let roomReferenceID = glove.relativeCalibrationID
        // Exact phone readings: system 3, gyro 0, accel 3, compass 3 then 2.
        for (levels, time): (UInt8, Double) in [(0xCF, 0.25), (0xCE, 0.4)] {
            poll(levels, at: time)
            #expect(glove.lastHeading?.degrees == 5)
            #expect(glove.message == "Glove pointing ready")
            #expect(glove.pointingSetupBlockingReason(now: epoch.addingTimeInterval(time + 0.02)) == nil)
            #expect(glove.calibrationID == northReferenceID)
            #expect(glove.relativeCalibrationID == roomReferenceID)
            #expect(glove.pointingCalibration?.finger == saved.finger)
        }
        try glove.send(.confirm(durationMs: 180, intensity: 204), now: epoch.addingTimeInterval(0.42))
        #expect(packets.last?[2] == 3 && packets.last?[7] == 1 && packets.last?[10] == 204)
        respond([0], at: 0.43)
        #expect(glove.lastMotorAcknowledgement == epoch.addingTimeInterval(0.43))
        // An actual loss of fused readiness still halts direction output.
        poll(0x8F, at: 0.55)
        #expect(glove.lastHeading == nil)
        #expect(glove.pointingCalibration?.finger == saved.finger)
        glove.tick(now: epoch.addingTimeInterval(0.57))
        #expect(packets.last?[2] == 3 && packets.last?[7] == 0)
    }

    @Test func missingNorthAndExcessiveUncertaintyHaveDifferentStatuses() throws {
        let glove = FirmwareGlove()
        var packets: [Data] = []
        glove.write = { packets.append($0) }
        func respond(_ payload: [UInt8], at seconds: Double) {
            var header = Array(packets.last!.prefix(7)); header[2] |= 0x80
            glove.receive(Data(header + payload), now: epoch.addingTimeInterval(seconds))
        }
        func poll(at seconds: Double) {
            glove.tick(now: epoch.addingTimeInterval(seconds))
            respond([0, 64, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0x72, 1], at: seconds + 0.01)
        }
        glove.beginLink(now: epoch)
        respond([31], at: 0.01)
        respond([0], at: 0.02)
        glove.calibrate(try calibration())
        poll(at: 0.1)
        #expect(glove.message?.contains("true-north correction") == true)
        #expect(glove.lastHeading == nil)
        glove.northCorrection = MagneticNorthCorrection(trueHeading: 5, magneticHeading: 0, accuracy: 25, timestamp: epoch)
        poll(at: 0.3)
        #expect(glove.message?.contains("uncertainty is too high") == true)
        #expect(glove.message?.contains("true-north correction") == false)
        #expect(glove.lastHeading == nil)
        glove.northCorrection = MagneticNorthCorrection(trueHeading: 5, magneticHeading: 0, accuracy: 5, timestamp: epoch)
        poll(at: 0.5)
        #expect(glove.lastHeading?.degrees == 5)
    }

    @Test func relaxedPulsesDoNotRelaxOutdoorGateAndStopWhenHandDrops() throws {
        let glove = FirmwareGlove()
        var packets: [Data] = []
        glove.write = { packets.append($0) }
        func respond(_ payload: [UInt8], at seconds: Double) {
            var header = Array(packets.last!.prefix(7)); header[2] |= 0x80
            glove.receive(Data(header + payload), now: epoch.addingTimeInterval(seconds))
        }
        glove.beginLink(now: epoch)
        respond([31], at: 0.01); respond([0], at: 0.02)
        glove.tick(now: epoch.addingTimeInterval(0.1))
        respond([0, 64, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0x30, 1], at: 0.11)
        glove.calibrate(try calibration())
        let cue = HapticCommand.confirm(durationMs: 180, intensity: 160)
        #expect(throws: GloveTransportError.self) { try glove.send(cue, now: epoch.addingTimeInterval(0.12)) }
        try glove.sendRelativeDemo(cue, now: epoch.addingTimeInterval(0.12))
        #expect(packets.last?[2] == 3)
        respond([0], at: 0.13)
        glove.tick(now: epoch.addingTimeInterval(0.22))
        respond([65, 45, 65, 45, 0, 0, 0, 0, 0, 0, 1, 0x30, 1], at: 0.23)
        #expect(throws: GloveTransportError.self) { try glove.sendRelativeDemo(cue, now: epoch.addingTimeInterval(0.24)) }
        glove.tick(now: epoch.addingTimeInterval(0.24))
        #expect(packets.last?[2] == 3 && packets.last?[7] == 0)
        #expect(glove.lastHeading == nil)
    }
    @Test func setupReadinessAndMountSurviveCompassAcquisitionAndLoss() throws {
        let glove = FirmwareGlove()
        var packets: [Data] = []
        glove.write = { packets.append($0) }
        func respond(_ payload: [UInt8], at seconds: Double) {
            var header = Array(packets.last!.prefix(7)); header[2] |= 0x80
            glove.receive(Data(header + payload), now: epoch.addingTimeInterval(seconds))
        }
        func poll(_ levels: UInt8, at seconds: Double) {
            glove.tick(now: epoch.addingTimeInterval(seconds))
            respond([0, 64, 0, 0, 0, 0, 0, 0, 0, 0, 1, levels, 1], at: seconds + 0.01)
        }
        glove.beginLink(now: epoch)
        respond([31], at: 0.01)
        respond([0], at: 0.02)
        poll(0x3D, at: 0.1)
        #expect(glove.pointingSetupBlockingReason(now: epoch.addingTimeInterval(0.12)) == nil)
        #expect(glove.pointingSetupBlockingReason(now: epoch.addingTimeInterval(0.7)) != nil)
        glove.calibrate(try calibration())
        poll(0x3D, at: 0.25)
        #expect(glove.pointingCalibration != nil && glove.lastHeading == nil)
        #expect(throws: GloveTransportError.self) { try glove.send(.confirm(durationMs: 180, intensity: 160), now: epoch.addingTimeInterval(0.27)) }
        glove.northCorrection = MagneticNorthCorrection(trueHeading: 5, magneticHeading: 0, accuracy: 2, timestamp: epoch)
        poll(0x72, at: 0.4)
        #expect(glove.lastHeading?.degrees == 5)
        let roomID = glove.calibrationID
        let relativeID = glove.relativeCalibrationID
        poll(0x3D, at: 0.55)
        #expect(glove.lastHeading == nil && glove.pointingCalibration != nil)
        #expect(glove.calibrationID != roomID) // Room reference needs a new alignment; finger axis does not.
        poll(0x72, at: 0.7)
        #expect(glove.lastHeading?.degrees == 5)
        poll(0x22, at: 0.85) // Gyro dip pauses guidance without erasing the fixed mounting.
        #expect(glove.pointingCalibration != nil)
        #expect(glove.relativePointing(now: epoch.addingTimeInterval(0.87)) == nil)
        #expect(glove.relativeCalibrationID == relativeID)
        poll(0x72, at: 1.0)
        #expect(glove.relativePointing(now: epoch.addingTimeInterval(1.02)) != nil)
        #expect(glove.relativeCalibrationID == relativeID)
        #expect(glove.pointingSetupBlockingReason(now: epoch.addingTimeInterval(1.02)) == nil)
    }

    @Test func exactSignedPacketAndCapabilityDependencies() throws {
        let token: UInt32 = 0x12345678
        let header: [UInt8] = [0xA7, 1, 0x85, 0x78, 0x56, 0x34, 0x12]
        let payload: [UInt8] = [0, 0xC0, 0, 0, 0, 0, 0, 0, 12, 0, 1, 255, 1]
        guard case .orientation(let q, let age, let health) = try FirmwareProtocol.reply(Data(header + payload), operation: .orientation, token: token) else {
            Issue.record("Expected quaternion reply"); return
        }
        #expect(q.rotate(SIMD3(1, 0, 0)) == SIMD3(1, 0, 0))
        #expect(age == 0.012 && health.calibration == 255)
        for bad in [Array(payload.dropLast()), payload + [0], Array(repeating: UInt8(0), count: 13)] {
            #expect(throws: FirmwareProtocol.PacketError.self) {
                try FirmwareProtocol.reply(Data(header + bad), operation: .orientation, token: token)
            }
        }
        for flags: UInt8 in [16, 17, 24, 32, 255] {
            #expect(throws: FirmwareProtocol.PacketError.self) {
                try FirmwareProtocol.reply(Data([0xA7, 1, 0x81, 0x78, 0x56, 0x34, 0x12, flags]), operation: .hello, token: token)
            }
        }
    }

    @Test func hardwareResetStopsMotorPreservesMountAndRejectsPreResetReadings() throws {
        let glove = FirmwareGlove()
        var packets: [Data] = []
        glove.write = { packets.append($0) }
        func respond(_ payload: [UInt8], at seconds: Double) {
            var b = Array(packets.last!.prefix(7)); b[2] |= 0x80
            glove.receive(Data(b + payload), now: epoch.addingTimeInterval(seconds))
        }
        glove.beginLink(now: epoch)
        respond([63], at: 0.01); respond([0], at: 0.02)
        glove.calibrate(try calibration())
        let mount = glove.pointingCalibration?.finger
        let reference = glove.relativeCalibrationID
        glove.tick(now: epoch.addingTimeInterval(0.1)) // Orientation request already in flight.
        try glove.recalibrateHardware(now: epoch.addingTimeInterval(0.11))
        #expect(glove.supportsHardwareCalibration && glove.hardwareCalibrationInProgress)
        #expect(glove.pointingCalibration?.finger == mount)
        #expect(glove.relativeCalibrationID != reference)
        respond([0,64,0,0,0,0,0,0,0,0,1,0x72,1], at: 0.12)
        #expect(glove.orientation == nil) // A queued old reading cannot undo the reset.
        glove.tick(now: epoch.addingTimeInterval(0.13))
        #expect(packets.last?[2] == 3 && packets.last?[7] == 0)
        respond([0], at: 0.14)
        glove.tick(now: epoch.addingTimeInterval(0.15))
        #expect(packets.last?[2] == 6)
        respond([0], at: 0.16)
        #expect(throws: GloveTransportError.self) { try glove.testMotor(now: epoch.addingTimeInterval(0.17)) }
        #expect(throws: GloveTransportError.self) { try glove.send(.vehicleArrived, now: epoch.addingTimeInterval(0.17)) }
        glove.tick(now: epoch.addingTimeInterval(0.25))
        respond([0,64,0,0,0,0,0,0,255,255,1,0,0], at: 0.26)
        #expect(glove.hardwareCalibrationInProgress && glove.orientation == nil)
        glove.tick(now: epoch.addingTimeInterval(0.4))
        respond([0,64,0,0,0,0,0,0,0,0,1,0x30,1], at: 0.41)
        #expect(!glove.hardwareCalibrationInProgress)
        #expect(glove.pointingCalibration?.finger == mount)
        #expect(glove.relativePointing(now: epoch.addingTimeInterval(0.42)) != nil)
    }

    @Test func savedMappingRestoresBeforeGyroSettlesAndDoesNotResetOnEverySample() throws {
        let suite = "PointMountRestoreTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PointingCalibrationStore(defaults: defaults)
        let device = UUID()
        let saved = try calibration()
        store.save(saved, for: device)
        let glove = FirmwareGlove()
        var packets: [Data] = []
        glove.write = { packets.append($0) }
        func respond(_ payload: [UInt8], at seconds: Double) {
            var b = Array(packets.last!.prefix(7)); b[2] |= 0x80
            glove.receive(Data(b + payload), now: epoch.addingTimeInterval(seconds))
        }
        #expect(!glove.restorePointingCalibration(from: store, for: device))
        glove.beginLink(now: epoch)
        respond([31], at: 0.01)
        respond([0], at: 0.02)
        glove.tick(now: epoch.addingTimeInterval(0.1))
        // Matches the screenshot: system 0, gyro 0, accel 1, compass 3.
        respond([0, 64, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0x07, 1], at: 0.11)
        #expect(!glove.restorePointingCalibration(from: store, for: UUID()))
        #expect(glove.restorePointingCalibration(from: store, for: device))
        #expect(glove.pointingCalibration?.finger == saved.finger)
        #expect(glove.relativePointing(now: epoch.addingTimeInterval(0.12)) == nil)
        #expect(glove.pointingSetupBlockingReason(now: epoch.addingTimeInterval(0.12)) != nil)
        let reference = glove.relativeCalibrationID
        #expect(!glove.restorePointingCalibration(from: store, for: device))
        #expect(glove.relativeCalibrationID == reference)
        glove.tick(now: epoch.addingTimeInterval(0.25))
        respond([0, 64, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0x37, 1], at: 0.26)
        #expect(glove.relativePointing(now: epoch.addingTimeInterval(0.27)) != nil)
        #expect(glove.relativeCalibrationID == reference)
    }

    @Test func setupEnablesGloveAndHandDownBlocksAutomaticMotorButNotExplicitTest() throws {
        let glove = FirmwareGlove()
        var packets: [Data] = []
        glove.write = { packets.append($0) }
        func respond(_ payload: [UInt8], at seconds: Double) {
            var b = Array(packets.last!.prefix(7)); b[2] |= 0x80
            glove.receive(Data(b + payload), now: epoch.addingTimeInterval(seconds))
        }
        glove.beginLink(now: epoch)
        respond([31], at: 0.01)
        respond([0], at: 0.02) // Startup stop
        glove.tick(now: epoch.addingTimeInterval(0.1))
        #expect(packets.last?[2] == 5)
        respond([0, 64, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0x72, 1], at: 0.11)
        #expect(glove.lastHeading == nil)
        glove.calibrate(try calibration())
        glove.northCorrection = MagneticNorthCorrection(trueHeading: 5, magneticHeading: 0, accuracy: 2, timestamp: epoch)
        glove.tick(now: epoch.addingTimeInterval(0.25))
        respond([0, 64, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0x72, 1], at: 0.26)
        #expect(glove.lastHeading?.degrees == 5)
        try glove.send(.confirm(durationMs: 180, intensity: 160), now: epoch.addingTimeInterval(0.27))
        respond([0], at: 0.28)
        glove.tick(now: epoch.addingTimeInterval(0.4))
        // 90° pitch about X: the Y-axis finger is now vertical.
        respond([65, 45, 65, 45, 0, 0, 0, 0, 0, 0, 1, 0x72, 1], at: 0.41)
        #expect(glove.lastHeading == nil)
        #expect(glove.magneticPointing(now: epoch.addingTimeInterval(0.42)) == nil)
        #expect(throws: GloveTransportError.self) { try glove.send(.confirm(durationMs: 180, intensity: 160), now: epoch.addingTimeInterval(0.42)) }
        glove.tick(now: epoch.addingTimeInterval(0.42))
        #expect(packets.last?[7] == 0) // Hand-down stops a running automatic pulse.
        respond([0], at: 0.425)
        try glove.testMotor(now: epoch.addingTimeInterval(0.43))
        #expect(packets.last?[2] == 3 && packets.last?[7] == 1)
        let oldID = glove.calibrationID
        glove.disconnect()
        #expect(glove.pointingCalibration == nil && glove.orientation == nil && glove.calibrationID != oldID)
    }

    @Test func loweringHandDuringTransitAlertDoesNotStopThePattern() throws {
        let glove = FirmwareGlove()
        var packets: [Data] = []
        glove.write = { packets.append($0) }
        func respond(_ payload: [UInt8], at seconds: Double) {
            var header = Array(packets.last!.prefix(7)); header[2] |= 0x80
            glove.receive(Data(header + payload), now: epoch.addingTimeInterval(seconds))
        }
        glove.beginLink(now: epoch)
        respond([31], at: 0.01); respond([0], at: 0.02)
        glove.calibrate(try calibration())
        glove.northCorrection = MagneticNorthCorrection(trueHeading: 5, magneticHeading: 0, accuracy: 2, timestamp: epoch)
        glove.tick(now: epoch.addingTimeInterval(0.1))
        respond([0,64,0,0,0,0,0,0,0,0,1,0x72,1], at: 0.11)
        #expect(glove.lastHeading != nil)
        try glove.send(.vehicleArrived, now: epoch.addingTimeInterval(0.12))
        #expect(packets.last?[2] == 3 && packets.last?[7] == 2)
        respond([0], at: 0.13)
        let sentBeforeHandDown = packets.count
        for time in [0.25, 0.4, 0.55, 0.7] {
            glove.tick(now: epoch.addingTimeInterval(time))
            #expect(packets.last?[2] == 5)
            respond([65,45,65,45,0,0,0,0,0,0,1,0x72,1], at: time + 0.01)
        }
        #expect(glove.lastHeading == nil)
        #expect(!packets.dropFirst(sentBeforeHandDown).contains { $0[2] == 3 })
        try glove.send(.stop, now: epoch.addingTimeInterval(0.72))
        #expect(packets.last?[2] == 3 && packets.last?[7] == 0)
    }
}
