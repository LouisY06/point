import Foundation
import Testing
@testable import PointCore

struct GloveConnectionMemoryTests {
    @Test func reconnectsOnlyLastVerifiedGloveAcrossLaunchesAndHonorsDisconnect() throws {
        let suite = "GloveConnectionMemoryTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = GloveConnectionMemory(defaults: defaults)
        #expect(store.automaticDevice == nil)
        let first = UUID(), second = UUID()
        store.rememberVerified(id: first, name: "Point S3")
        #expect(GloveConnectionMemory(defaults: defaults).automaticDevice?.id == first)
        store.pauseAutomaticConnection()
        let reopened = GloveConnectionMemory(defaults: defaults)
        #expect(reopened.automaticDevice == nil)
        #expect(reopened.device?.id == first)
        reopened.rememberVerified(id: second, name: "Point S3") // Identical name, distinct identity.
        #expect(store.automaticDevice?.id == second)
        #expect(store.automaticDevice?.name == "Point S3")
    }
}
