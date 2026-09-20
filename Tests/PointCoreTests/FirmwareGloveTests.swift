import CoreLocation
import Foundation
import Testing
@testable import PointCore

@MainActor private final class FirmwareRig {
    let glove = FirmwareGlove()
    var packets: [Data] = []
    let start = Date(timeIntervalSince1970: 10_000)
    init() { glove.write = { [weak self] in self?.packets.append($0) } }
    func time(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }
    func response(to request: Data? = nil, payload: [UInt8]) -> Data {
        var b = Array((request ?? packets.last!).prefix(7))
        b[2] |= 0x80
        return Data(b + payload)
    }
    func ready(flags: UInt8 = 7) {
        glove.beginLink(now: start)
        glove.receive(response(payload: [flags]), now: time(0.01))
        glove.tick(now: time(0.02)) // Required initial stop.
        if flags & 2 != 0 { glove.receive(response(payload: [0]), now: time(0.03)) }
    }
    func sample(reference: UInt8 = 2, age: UInt16 = 0) -> Data {
        response(payload: [0, 0, 200, 0, reference, UInt8(truncatingIfNeeded: age), UInt8(age >> 8)])
    }
}

@MainActor struct FirmwareGloveTests {
    @Test func hardwareCalibrationRequiresNegotiatedSupportAndValidReply() throws {
        let legacy = FirmwareRig(); legacy.ready(flags: 31)
        #expect(!legacy.glove.supportsHardwareCalibration)
        #expect(throws: GloveTransportError.self) { try legacy.glove.recalibrateHardware(now: legacy.time(0.04)) }
        let request = try FirmwareProtocol.request(.recalibrateSensors, token: 0x12345678)
        #expect(Array(request) == [0xA7,1,6,0x78,0x56,0x34,0x12])
        let header: [UInt8] = [0xA7,1,0x86,0x78,0x56,0x34,0x12]
        if case .recalibration(let accepted) = try FirmwareProtocol.reply(Data(header + [0]), operation: .recalibrateSensors, token: 0x12345678) {
            #expect(accepted)
        } else { Issue.record("Wrong reset reply") }
        for payload: [UInt8] in [[], [2], [0,0]] {
            #expect(throws: FirmwareProtocol.PacketError.self) {
                try FirmwareProtocol.reply(Data(header + payload), operation: .recalibrateSensors, token: 0x12345678)
            }
        }
    }

    @Test func legacyEchoDoesNotUnlockMotorControls() throws {
        let r = FirmwareRig()
        r.glove.beginLink(now: r.start)
        #expect(r.packets[0].count <= 16)
        r.glove.receive(Data("ACK:".utf8) + r.packets[0], now: r.time(0.1))
        #expect(r.glove.state == .negotiating)
        r.glove.tick(now: r.time(2.1))
        #expect(r.glove.state == .echoOnly)
        #expect(throws: GloveTransportError.self) { try r.glove.send(.confirm(durationMs: 180, intensity: 160)) }
    }

    @Test func malformedUnknownAndOldPacketsCannotNegotiate() {
        let r = FirmwareRig()
        r.glove.beginLink(now: r.start)
        let old = r.response(payload: [7])
        r.glove.beginLink(now: r.time(1))
        var wrongVersion = Array(r.response(payload: [7])); wrongVersion[1] = 2
        for data in [old, Data(wrongVersion), r.response(payload: [255]), r.response(payload: [4]), r.response(payload: [7, 0]), Data()] {
            r.glove.receive(data, now: r.time(1.1))
            #expect(r.glove.state == .negotiating)
        }
        r.glove.receive(r.response(payload: [3]), now: r.time(1.2))
        #expect(r.glove.state == .ready)
        #expect(r.glove.capabilities?.vibration == true)
        #expect(throws: GloveTransportError.self) { try r.glove.send(.vehicleArrived) }
    }

    @Test func relativeYawStaysRelativeAndRoundTripCountsAgainstFreshness() {
        let r = FirmwareRig(); r.ready()
        r.glove.tick(now: r.time(0.1))
        r.glove.receive(r.sample(reference: 0, age: 100), now: r.time(0.3))
        #expect(r.glove.lastHeading?.reference == .relative)
        #expect(abs(r.glove.lastHeading!.timestamp.timeIntervalSince(r.start)) < 0.001)
        r.glove.tick(now: r.time(0.4))
        let packet = r.sample(age: 400)
        r.glove.receive(packet, now: r.time(0.6)) // 600 ms total age, rejected.
        #expect(r.glove.lastHeading == nil)
        r.glove.tick(now: r.time(0.7))
        r.glove.receive(packet, now: r.time(0.71)) // Wrong request token, also rejected.
        #expect(r.glove.lastHeading == nil)
    }

    @Test func stalledLinkCannotAccumulateOrReplayMotorHistory() throws {
        let r = FirmwareRig(); r.ready()
        r.glove.tick(now: r.time(0.1))
        let count = r.packets.count
        for i in 1...1000 {
            try r.glove.send(.confirm(durationMs: 180, intensity: UInt8(i % 200)), now: r.time(0.11))
        }
        #expect(r.packets.count == count)
        r.glove.receive(r.sample(), now: r.time(0.2))
        r.glove.tick(now: r.time(0.21))
        #expect(r.packets.count == count + 1)
        #expect(r.packets.last?.last == 0) // Only final requested intensity survives.
        r.glove.receive(r.response(payload: [0]), now: r.time(0.22))
        r.glove.tick(now: r.time(0.23))
        #expect(r.packets.last?[2] == 2) // Heading request, no remaining motor backlog.
    }

    @Test func stopTakesPriorityAndExpiredCuesAreDiscarded() throws {
        let r = FirmwareRig(); r.ready()
        r.glove.tick(now: r.time(0.1))
        try r.glove.send(.confirm(durationMs: 180, intensity: 160), now: r.time(0.11))
        try r.glove.send(.stop, now: r.time(0.12))
        #expect(throws: GloveTransportError.self) { try r.glove.send(.vehicleArrived, now: r.time(0.13)) }
        r.glove.receive(r.sample(), now: r.time(0.2))
        r.glove.tick(now: r.time(0.21))
        #expect(r.packets.last?[7] == 0)
        r.glove.receive(r.response(payload: [0]), now: r.time(0.22))
        r.glove.tick(now: r.time(0.3))
        try r.glove.send(.vehicleArrived, now: r.time(0.31))
        r.glove.receive(r.sample(), now: r.time(0.7))
        r.glove.tick(now: r.time(0.71))
        #expect(r.packets.last?[2] == 2) // Stale arrival not played.
    }

    @Test func rejectionTimeoutAndDisconnectClearReadiness() throws {
        let r = FirmwareRig(); r.ready()
        try r.glove.send(.confirm(durationMs: 180, intensity: 160), now: r.time(0.1))
        r.glove.receive(r.response(payload: [1]), now: r.time(0.11))
        #expect(r.glove.state == .failed)
        #expect(r.glove.connection == .disconnected)
        let count = r.packets.count
        r.glove.writeFailed() // Failed best-effort stop must not cause an infinite retry.
        #expect(r.packets.count == count)
        r.ready()
        r.glove.tick(now: r.time(0.1))
        let late = r.sample()
        r.glove.tick(now: r.time(0.61))
        #expect(r.glove.state == .failed)
        r.glove.disconnect()
        r.glove.receive(late, now: r.time(0.7))
        #expect(r.glove.lastHeading == nil)
        #expect(r.glove.capabilities == nil)
    }

    @Test func motorPacketsHaveKnownVectorsAndHardBounds() throws {
        #expect(try FirmwareProtocol.request(.haptic, token: 0x12345678,
                                            command: .confirm(durationMs: 180, intensity: 160)) ==
                Data([0xA7, 1, 3, 0x78, 0x56, 0x34, 0x12, 1, 180, 0, 160]))
        for command: HapticCommand in [.confirm(durationMs: 0, intensity: 160),
                                       .confirm(durationMs: 351, intensity: 160),
                                       .confirm(durationMs: 180, intensity: 255)] {
            #expect(throws: FirmwareProtocol.PacketError.self) {
                try FirmwareProtocol.request(.haptic, token: 1, command: command)
            }
        }
    }

    @Test func controllerSwitchDropsSimulatorHeadingAndSuspensionStopsOutput() throws {
        let sim = SimulatedGlove()
        let point = PointController(glove: sim)
        let now = Date()
        let origin = CLLocationCoordinate2D(latitude: 42, longitude: -71)
        let north = CLLocationCoordinate2D(latitude: 42.001, longitude: -71)
        let route = RoutePlan(destinationName: "North", checkpoints: [
            .init(coordinate: origin, distanceFromStartMeters: 0, stepIndex: 0, stepInstruction: "North", bearingToNextDegrees: 0),
            .init(coordinate: north, distanceFromStartMeters: 111, stepIndex: 0, stepInstruction: "Arrive", bearingToNextDegrees: 0)
        ], beacons: [.init(coordinate: north, instruction: "North", isFinalDestination: true, bearingAfterTurnDegrees: 0)])
        sim.connect()
        try point.start(route)
        point.updateLocation(CLLocation(coordinate: origin, altitude: 0, horizontalAccuracy: 2,
                                        verticalAccuracy: 2, timestamp: now), now: now)
        point.receive(.heading(.init(degrees: 0, accuracyDegrees: 2, timestamp: now, reference: .trueNorth)), now: now)
        point.receive(.heading(.init(degrees: 0, accuracyDegrees: 2, timestamp: now.addingTimeInterval(0.4), reference: .trueNorth)), now: now.addingTimeInterval(0.4))
        #expect(point.feedback.shouldConfirm)
        point.receive(.headingUnavailable, now: now.addingTimeInterval(0.41))
        #expect(!point.feedback.shouldConfirm)
        #expect(sim.commands.last == .stop)
        point.setOutputEnabled(false)
        #expect(sim.commands.last == .stop)
        point.emit(.vehicleArrived)
        #expect(sim.commands.last == .stop)
        let live = FirmwareGlove()
        point.useTransport(live)
        point.setOutputEnabled(true)
        #expect(point.connection == .disconnected)
        #expect(!point.feedback.shouldConfirm)
    }

    @Test func bno055NegotiatesHealthAndCorrectsMagneticNorth() {
        let r = FirmwareRig(); r.ready(flags: 15)
        r.glove.northCorrection = MagneticNorthCorrection(trueHeading: 105, magneticHeading: 100,
                                                          accuracy: 2, timestamp: r.start)
        r.glove.tick(now: r.time(0.1))
        #expect(r.packets.last?[2] == 4)
        // Magnetic 359°, uncertainty 2°, BNO055, calibration 3/3/3/3, healthy/mapped.
        r.glove.receive(r.response(payload: [0x3C, 0x8C, 200, 0, 1, 0, 0, 1, 255, 3]), now: r.time(0.11))
        #expect(r.glove.lastHeading?.degrees == 4)
        #expect(r.glove.lastHeading?.reference == .trueNorth)
        #expect(r.glove.lastHeading?.accuracyDegrees == 4)
        #expect(r.glove.sensorHealth?.source == .bno055)
    }

    @Test func calibrationLossFaultDisagreementAndFallbackImmediatelyInvalidate() {
        for (source, calibration, flags): (UInt8, UInt8, UInt8) in [
            (1, 253, 3), (1, 255, 2), (1, 255, 1), (1, 255, 7), (1, 255, 11), (2, 255, 3)
        ] {
            let r = FirmwareRig(); r.ready(flags: 15)
            var invalidations = 0
            r.glove.onEvent = { if case .headingUnavailable = $0 { invalidations += 1 } }
            r.glove.tick(now: r.time(0.1))
            r.glove.receive(r.response(payload: [0, 0, 200, 0, 2, 0, 0, 1, 255, 3]), now: r.time(0.11))
            #expect(r.glove.lastHeading != nil)
            r.glove.tick(now: r.time(0.25))
            r.glove.receive(r.response(payload: [0, 0, 200, 0, 2, 0, 0, source, calibration, flags]), now: r.time(0.26))
            #expect(r.glove.lastHeading == nil)
            #expect(invalidations == 1)
            #expect(r.glove.connection == .ready) // Motor testing remains available.
        }
    }

    @Test func magneticBnoNeedsFreshCorrectionButFirmwareTrueNorthIsNotCorrectedTwice() {
        let r = FirmwareRig(); r.ready(flags: 15)
        r.glove.tick(now: r.time(0.1))
        r.glove.receive(r.response(payload: [0, 0, 200, 0, 1, 0, 0, 1, 255, 3]), now: r.time(0.11))
        #expect(r.glove.lastHeading == nil)
        #expect(r.glove.message?.contains("correction") == true)
        r.glove.northCorrection = MagneticNorthCorrection(trueHeading: 105, magneticHeading: 100,
                                                          accuracy: 2, timestamp: r.start)
        r.glove.tick(now: r.time(0.25))
        r.glove.receive(r.response(payload: [0, 0, 200, 0, 2, 0, 0, 1, 255, 3]), now: r.time(0.26))
        #expect(r.glove.lastHeading?.degrees == 0)
        r.glove.disconnect()
        #expect(r.glove.sensorHealth == nil)
        #expect(r.glove.northCorrection == nil)
    }

    @Test func extendedPacketsRequireExactShapeAndValidSensorIdentity() throws {
        let r = FirmwareRig(); r.ready(flags: 15)
        r.glove.tick(now: r.time(0.1))
        for payload: [UInt8] in [
            [0, 0, 200, 0, 2, 0, 0], // Old heading response cannot satisfy new opcode.
            [0, 0, 200, 0, 2, 0, 0, 3, 255, 3], // Unknown sensor.
            [0, 0, 200, 0, 2, 0, 0, 1, 255, 0x13] // Unknown health flags.
        ] {
            r.glove.receive(r.response(payload: payload), now: r.time(0.11))
            #expect(r.glove.sensorHealth == nil)
            #expect(r.glove.lastHeading == nil)
        }
        r.glove.receive(r.response(payload: [0, 0, 200, 0, 1, 0, 0, 1, 0xE4, 3]), now: r.time(0.12))
        let health = try #require(r.glove.sensorHealth)
        #expect(health.system == 3 && health.gyro == 2 && health.accelerometer == 1 && health.magnetometer == 0)
    }

    @Test func headingExpiresWithoutNewPackets() {
        let r = FirmwareRig(); r.ready(flags: 15)
        var invalidated = false
        r.glove.onEvent = { if case .headingUnavailable = $0 { invalidated = true } }
        r.glove.tick(now: r.time(0.1))
        r.glove.receive(r.response(payload: [0, 0, 200, 0, 2, 0, 0, 1, 255, 3]), now: r.time(0.11))
        r.glove.tick(now: r.time(0.61))
        #expect(r.glove.lastHeading == nil)
        #expect(invalidated)
    }

    @Test func magneticCorrectionHandlesWraparoundOrientationAndInvalidSamples() throws {
        let now = Date()
        let reading = HeadingReading(degrees: 2, accuracyDegrees: 3, timestamp: now, reference: .magneticNorth)
        let west = try #require(MagneticNorthCorrection(trueHeading: 355, magneticHeading: 5, accuracy: 2, timestamp: now))
        #expect(west.degrees == -10)
        #expect(west.apply(to: reading, now: now)?.degrees == 352)
        let rotatedPhone = try #require(MagneticNorthCorrection(trueHeading: 95, magneticHeading: 105, accuracy: 2, timestamp: now))
        #expect(rotatedPhone.apply(to: reading, now: now)?.degrees == 352)
        let old = try #require(MagneticNorthCorrection(trueHeading: 0, magneticHeading: 5, accuracy: 2,
                                                      timestamp: now.addingTimeInterval(-6)))
        #expect(old.apply(to: reading, now: now) == nil)
        #expect(west.apply(to: reading, now: now.addingTimeInterval(-1)) == nil)
        for invalid in [-1.0, 360, Double.nan, .infinity] {
            #expect(MagneticNorthCorrection(trueHeading: invalid, magneticHeading: 0, accuracy: 2, timestamp: now) == nil)
        }
        #expect(MagneticNorthCorrection(trueHeading: 0, magneticHeading: 0, accuracy: -1, timestamp: now) == nil)
        let relative = HeadingReading(degrees: 2, accuracyDegrees: 3, timestamp: now, reference: .relative)
        #expect(west.apply(to: relative, now: now) == nil)
    }
}
