import Foundation
import Testing
@testable import PointCore

struct BTTestProtocolTests {
    @Test func commandsRespectFirmwareByteLimit() throws {
        #expect(try BTTestProtocol.command("").isEmpty)
        #expect(try BTTestProtocol.command(String(repeating: "a", count: 16)).count == 16)
        #expect(throws: BTTestProtocol.CommandError.self) {
            try BTTestProtocol.command(String(repeating: "a", count: 17))
        }
        #expect(try BTTestProtocol.command("🧤🧤🧤🧤").count == 16)
        #expect(throws: BTTestProtocol.CommandError.self) {
            try BTTestProtocol.command("🧤🧤🧤🧤a")
        }
    }

    @Test func probeFitsDefaultATTMTU() throws {
        let probe = try BTEchoProbe()
        #expect(probe.command.count <= 16)
        #expect((Data("ACK:".utf8) + probe.command).count <= 20)
        #expect(throws: BTTestProtocol.CommandError.self) {
            try BTEchoProbe(token: String(repeating: "a", count: 15))
        }
    }

    @Test func genericAndStaleStatusesDoNotVerifyConnection() throws {
        var probe = try BTEchoProbe(token: "current")
        probe.acknowledgeWrite()
        for value in ["ready", "connected", "ACK:P:previous", "ACK:P:current-extra", "ACK:"] {
            probe.receive(Data(value.utf8))
            #expect(!probe.isVerified)
        }
        probe.receive(Data("ACK:P:current".utf8))
        #expect(probe.isVerified)
    }

    @Test func writeAndNotificationMayArriveInEitherOrder() throws {
        var notificationFirst = try BTEchoProbe(token: "one")
        notificationFirst.receive(Data("ACK:P:one".utf8))
        #expect(!notificationFirst.isVerified)
        notificationFirst.acknowledgeWrite()
        #expect(notificationFirst.isVerified)

        var writeFirst = try BTEchoProbe(token: "two")
        writeFirst.acknowledgeWrite()
        #expect(!writeFirst.isVerified)
        writeFirst.receive(Data("ACK:P:two".utf8))
        #expect(writeFirst.isVerified)
    }

    @Test func newProbeCannotInheritAnEarlierVerification() throws {
        var probe = try BTEchoProbe(token: "old")
        probe.acknowledgeWrite()
        probe.receive(Data("ACK:P:old".utf8))
        #expect(probe.isVerified)
        probe = try BTEchoProbe(token: "new")
        probe.receive(Data("ACK:P:old".utf8))
        probe.acknowledgeWrite()
        #expect(!probe.isVerified)
    }
}
