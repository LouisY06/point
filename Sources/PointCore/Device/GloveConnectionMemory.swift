import Foundation

/// Remembers only the last verified Bluetooth peripheral, never a name-matched substitute.
public final class GloveConnectionMemory {
    public struct Device: Codable, Equatable {
        public let id: UUID
        public let name: String
    }
    private let defaults: UserDefaults
    private let deviceKey = "point.last-glove.v1"
    private let pausedKey = "point.glove-autoconnect-paused.v1"
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public var device: Device? {
        guard let data = defaults.data(forKey: deviceKey) else { return nil }
        return try? JSONDecoder().decode(Device.self, from: data)
    }
    public var automaticDevice: Device? { defaults.bool(forKey: pausedKey) ? nil : device }
    public func rememberVerified(id: UUID, name: String) {
        guard let data = try? JSONEncoder().encode(Device(id: id, name: name)) else { return }
        defaults.set(data, forKey: deviceKey)
        defaults.set(false, forKey: pausedKey)
    }
    public func pauseAutomaticConnection() { defaults.set(true, forKey: pausedKey) }
}
