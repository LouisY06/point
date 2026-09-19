import Foundation

/// The echo-only contract implemented in Firmware/BTTest. This is not the navigation protocol.
public enum BTTestProtocol {
    public static let serviceUUID = "7f510001-1b15-4f0d-9e82-8a7c4d6e5f01"
    public static let commandUUID = "7f510002-1b15-4f0d-9e82-8a7c4d6e5f01"
    public static let statusUUID = "7f510003-1b15-4f0d-9e82-8a7c4d6e5f01"
    public static let maximumCommandBytes = 16

    public enum CommandError: Error { case tooLong }

    public static func command(_ text: String) throws -> Data {
        let bytes = Data(text.utf8)
        guard bytes.count <= maximumCommandBytes else { throw CommandError.tooLong }
        return bytes
    }
}

/// Require both an acknowledged GATT write and the exact echoed payload. A generic
/// "connected" status or an ACK from an earlier attempt must never verify a new link.
public struct BTEchoProbe {
    public let command: Data
    private var writeAcknowledged = false
    private var echoReceived = false
    public var isVerified: Bool { writeAcknowledged && echoReceived }

    public init(token: String = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))) throws {
        command = try BTTestProtocol.command("P:" + token)
    }

    public mutating func acknowledgeWrite() { writeAcknowledged = true }

    public mutating func receive(_ data: Data) {
        if data == Data("ACK:".utf8) + command { echoReceived = true }
    }
}
