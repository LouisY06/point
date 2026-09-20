import CoreLocation
import Foundation
import Testing
@testable import PointCore

struct MagneticNorthCorrectionCacheTests {
    private let start = Date(timeIntervalSince1970: 10_000)

    private func time(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }
    private func fix(_ seconds: Double = 0, latitude: Double = 42.36, accuracy: Double = 100) -> CLLocation {
        CLLocation(coordinate: .init(latitude: latitude, longitude: -71.09), altitude: 0,
                   horizontalAccuracy: accuracy, verticalAccuracy: -1, timestamp: time(seconds))
    }
    private func seeded() -> MagneticNorthCorrectionCache {
        var cache = MagneticNorthCorrectionCache()
        cache.update(trueHeading: 355, magneticHeading: 5, accuracy: 2,
                     timestamp: start, location: fix(), now: start)
        return cache
    }

    @Test func neighbourhoodFixCanEstablishNorthAndRotationKeepsTheSameCorrection() throws {
        var cache = seeded()
        let first = cache.correction(at: fix(), now: start)
        #expect(try #require(first).degrees == -10)
        cache.update(trueHeading: 95, magneticHeading: 105, accuracy: 2,
                     timestamp: time(10), location: fix(10), now: time(10))
        let rotated = cache.correction(at: fix(10), now: time(10))
        let correction = try #require(rotated)
        #expect(correction.degrees == -10)
        #expect(correction.timestamp == time(10))
    }

    @Test func dropoutsAndNoisyUpdatesKeepTheBetterReferenceWithoutRenewingIt() throws {
        var cache = seeded()
        cache.update(trueHeading: -1, magneticHeading: 0, accuracy: -1,
                     timestamp: time(10), location: fix(10), now: time(10))
        cache.update(trueHeading: 100, magneticHeading: 105, accuracy: 20,
                     timestamp: time(20), location: fix(20), now: time(20))
        cache.update(trueHeading: 100, magneticHeading: 105, accuracy: 1,
                     timestamp: time(30), location: fix(30, accuracy: 2_000), now: time(30))
        cache.update(trueHeading: 100, magneticHeading: 105, accuracy: 1,
                     timestamp: time(40), location: nil, now: time(40))
        let cached = cache.correction(at: fix(), now: time(120))
        let retained = try #require(cached)
        #expect(retained.degrees == -10 && retained.uncertainty == 2)
        #expect(retained.timestamp == start)
        let live = HeadingReading(degrees: 2, accuracyDegrees: 3, timestamp: time(120), reference: .magneticNorth)
        #expect(retained.apply(to: live, now: time(120))?.degrees == 352)
        #expect(retained.apply(to: live, now: time(120))?.accuracyDegrees == 5)
    }

    @Test func betterReferenceRefreshesButDelayedOrInvalidHeadingDoesNot() throws {
        var cache = seeded()
        cache.update(trueHeading: 95, magneticHeading: 105, accuracy: 1,
                     timestamp: time(10), location: fix(10), now: time(10))
        for sampleTime in [0.0, 11, 30] {
            cache.update(trueHeading: 40, magneticHeading: 50, accuracy: 0,
                         timestamp: time(sampleTime), location: fix(20), now: time(20))
        }
        let cached = cache.correction(at: fix(20), now: time(20))
        let correction = try #require(cached)
        #expect(correction.timestamp == time(10))
        #expect(correction.uncertainty == 1)
    }

    @Test func referenceExpiresAndCannotBeRevivedWithoutANewValidPair() throws {
        var cache = seeded()
        let cached = cache.correction(at: nil, now: start)
        let correction = try #require(cached)
        let expiry = MagneticNorthCorrection.maximumAge + 1
        #expect(cache.correction(at: fix(expiry), now: time(expiry)) == nil)
        // A caller retaining a copy cannot bypass the age bound.
        let live = HeadingReading(degrees: 0, accuracyDegrees: 2, timestamp: time(expiry), reference: .magneticNorth)
        #expect(correction.apply(to: live, now: time(expiry)) == nil)
        #expect(cache.correction(at: fix(), now: start) == nil)
        cache.update(trueHeading: 90, magneticHeading: 100, accuracy: 4,
                     timestamp: time(expiry), location: fix(expiry), now: time(expiry))
        #expect(cache.correction(at: fix(expiry), now: time(expiry)) != nil)
    }

    @Test func movingOutsideTheLocalAreaInvalidatesBeforeTheNextHeadingCallback() {
        var cache = seeded()
        #expect(cache.correction(at: fix(20, latitude: 42.365), now: time(20)) != nil)
        #expect(cache.correction(at: fix(40, latitude: 42.39), now: time(40)) == nil)
        #expect(cache.correction(at: fix(50), now: time(50)) == nil)
        cache.update(trueHeading: 90, magneticHeading: 99, accuracy: 3,
                     timestamp: time(60), location: fix(60, latitude: 42.39), now: time(60))
        #expect(cache.correction(at: fix(60, latitude: 42.39), now: time(60))?.degrees == -9)
    }

    @Test func badLocationCannotSeedAndPermissionResetRemovesTheReference() {
        for location in [fix(0, latitude: 100), fix(0, accuracy: -1), fix(0, accuracy: 251), fix(-61), fix(1)] {
            var cache = MagneticNorthCorrectionCache()
            cache.update(trueHeading: 355, magneticHeading: 5, accuracy: 2,
                         timestamp: start, location: location, now: start)
            #expect(cache.correction(at: nil, now: start) == nil)
        }
        var cache = seeded()
        cache.clear()
        #expect(cache.correction(at: fix(), now: start) == nil)
    }

    @Test func cachedNorthNeverMakesAStaleOrRelativeGloveSampleUsable() throws {
        var cache = seeded()
        let cached = cache.correction(at: nil, now: time(120))
        let correction = try #require(cached)
        let stale = HeadingReading(degrees: 10, accuracyDegrees: 2, timestamp: time(119), reference: .magneticNorth)
        let relative = HeadingReading(degrees: 10, accuracyDegrees: 2, timestamp: time(120), reference: .relative)
        #expect(correction.apply(to: stale, now: time(120)) == nil)
        #expect(correction.apply(to: relative, now: time(120)) == nil)
        #expect(cache.correction(at: nil, now: time(-1)) == nil)
    }
}
