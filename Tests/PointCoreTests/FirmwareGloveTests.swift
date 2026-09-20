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
        let prior = r.glove.lastHeading!.timestamp
        r.glove.tick(now: r.time(0.4))
        let packet = r.sample(age: 400)
        r.glove.receive(packet, now: r.time(0.6)) // 600 ms total age, rejected.
        #expect(r.glove.lastHeading?.timestamp == prior)
        r.glove.tick(now: r.time(0.7))
        r.glove.receive(packet, now: r.time(0.71)) // Wrong request token, also rejected.
        #expect(r.glove.lastHeading?.timestamp == prior)
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
}
