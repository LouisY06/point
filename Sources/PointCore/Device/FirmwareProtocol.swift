import Foundation

/// Proposed S3 protocol v1. The Arduino circuit sketch and legacy C6 echo service
/// do NOT implement this contract. See docs/FIRMWARE_APP_PROTOCOL.md.
public enum FirmwareProtocol {
    public enum Operation: UInt8 { case hello = 1, heading = 2, haptic = 3 }
    public enum PacketError: Error { case malformed, unsupportedCommand }
    public enum Reply {
        case capabilities(GloveCapabilities)
        case heading(degrees: Double, accuracy: Double, reference: HeadingReference, age: TimeInterval)
        case haptic(accepted: Bool)
    }

    public static func request(_ operation: Operation, token: UInt32, command: HapticCommand? = nil) throws -> Data {
        var bytes: [UInt8] = [0xA7, 1, operation.rawValue]
        bytes += (0..<4).map { UInt8(truncatingIfNeeded: token >> ($0 * 8)) }
        if operation == .haptic {
            switch command {
            case .stop: bytes += [0, 0, 0, 0]
            case .confirm(let duration, let intensity):
                guard (1...350).contains(duration), intensity <= 204 else { throw PacketError.unsupportedCommand }
                bytes += [1, UInt8(truncatingIfNeeded: duration), UInt8(duration >> 8), intensity]
            case .vehicleArrived: bytes += [2, 0, 0, 0]
            case nil: throw PacketError.unsupportedCommand
            }
        }
        return Data(bytes)
    }

    public static func reply(_ data: Data, operation: Operation, token: UInt32) throws -> Reply {
        let b = Array(data)
        let tokenBytes = (0..<4).map { UInt8(truncatingIfNeeded: token >> ($0 * 8)) }
        guard b.count >= 7, b[0] == 0xA7, b[1] == 1,
              b[2] == (operation.rawValue | 0x80), Array(b[3..<7]) == tokenBytes else {
            throw PacketError.malformed
        }
        func u16(_ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
        switch operation {
        case .hello:
            guard b.count == 8, b[7] & ~UInt8(7) == 0,
                  b[7] & 4 == 0 || b[7] & 2 != 0 else { throw PacketError.malformed }
            // v1 intentionally has no gesture/battery messages. Bit 2 advertises the
            // bounded vehicle-arrival cue, consumed separately by the transport.
            return .capabilities(GloveCapabilities(heading: b[7] & 1 != 0, gestures: false, vibration: b[7] & 2 != 0))
        case .heading:
            guard b.count == 14, u16(7) < 36000, u16(9) <= 18000, b[11] <= 2 else { throw PacketError.malformed }
            let reference: HeadingReference = b[11] == 0 ? .relative : b[11] == 1 ? .magneticNorth : .trueNorth
            return .heading(degrees: Double(u16(7)) / 100, accuracy: Double(u16(9)) / 100,
                            reference: reference, age: Double(u16(12)) / 1000)
        case .haptic:
            guard b.count == 8, b[7] <= 1 else { throw PacketError.malformed }
            return .haptic(accepted: b[7] == 0)
        }
    }
}
