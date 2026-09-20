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
        feed(&cache, trueHeading: 355, magneticHeading: 5, at: 0)
        return cache
    }

    private func feed(_ cache: inout MagneticNorthCorrectionCache, trueHeading: Double, magneticHeading: Double,
                      accuracy: Double = 20, at seconds: Double, latitude: Double = 42.36) {
        for offset in [-0.4, -0.2, 0.0] {
            let t = seconds + offset
            cache.update(trueHeading: trueHeading, magneticHeading: magneticHeading, accuracy: accuracy,
                         timestamp: time(t), location: fix(t, latitude: latitude), now: time(t))
        }
    }

    @Test func neighbourhoodFixCanEstablishNorthAndRotationKeepsTheSameCorrection() throws {
        var cache = seeded()
        let first = cache.correction(at: fix(), now: start)
        #expect(try #require(first).degrees == -10)
        feed(&cache, trueHeading: 95, magneticHeading: 105, at: 10)
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
        #expect(retained.degrees == -10 && retained.uncertainty == 5)
        #expect(retained.timestamp == start)
        let live = HeadingReading(degrees: 2, accuracyDegrees: 3, timestamp: time(120), reference: .magneticNorth)
        #expect(retained.apply(to: live, now: time(120))?.degrees == 352)
        #expect(retained.apply(to: live, now: time(120))?.accuracyDegrees == 8)
    }

    @Test func stableReferenceRefreshesButDelayedOrInvalidHeadingDoesNot() throws {
        var cache = seeded()
        feed(&cache, trueHeading: 95, magneticHeading: 105, at: 10)
        for sampleTime in [0.0, 11, 30] {
            cache.update(trueHeading: 40, magneticHeading: 50, accuracy: 0,
                         timestamp: time(sampleTime), location: fix(20), now: time(20))
        }
        let cached = cache.correction(at: fix(20), now: time(20))
        let correction = try #require(cached)
        #expect(correction.timestamp == time(10))
        #expect(correction.uncertainty == 5)
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
        feed(&cache, trueHeading: 90, magneticHeading: 100, at: expiry)
        #expect(cache.correction(at: fix(expiry), now: time(expiry)) != nil)
    }

    @Test func movingOutsideTheLocalAreaInvalidatesBeforeTheNextHeadingCallback() {
        var cache = seeded()
        #expect(cache.correction(at: fix(20, latitude: 42.365), now: time(20)) != nil)
        #expect(cache.correction(at: fix(40, latitude: 42.39), now: time(40)) == nil)
        #expect(cache.correction(at: fix(50), now: time(50)) == nil)
        feed(&cache, trueHeading: 90, magneticHeading: 99, at: 60, latitude: 42.39)
        #expect(cache.correction(at: fix(60, latitude: 42.39), now: time(60))?.degrees == -9)
    }

    @Test func badLocationCannotSeedAndPermissionResetRemovesTheReference() {
        for location in [fix(0, latitude: 100), fix(0, accuracy: -1), fix(0, accuracy: 251), fix(-61), fix(1)] {
            var cache = MagneticNorthCorrectionCache()
            for seconds in [0.0, 0.2, 0.4] {
                cache.update(trueHeading: 355, magneticHeading: 5, accuracy: 2,
                             timestamp: time(seconds), location: location, now: time(seconds))
            }
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

    @Test func phoneAzimuthUncertaintyIsNotAddedToGlovePointingUncertainty() throws {
        // Recorded failure: the phone knew the -13.916° local correction, but its
        // 18.812° compass error plus the 12.432° glove estimate exceeded the 25° gate.
        for phoneAccuracy in [18.812, 48.059, 90.0] {
            var cache = MagneticNorthCorrectionCache()
            feed(&cache, trueHeading: 82.321, magneticHeading: 96.237, accuracy: phoneAccuracy, at: 0)
            let cached = cache.correction(at: fix(), now: start)
            let correction = try #require(cached)
            let glove = HeadingReading(degrees: 40, accuracyDegrees: 12.432, timestamp: start, reference: .magneticNorth)
            let result = try #require(correction.apply(to: glove, now: start))
            #expect(abs(result.degrees - 26.084) < 0.001)
            #expect(abs(result.accuracyDegrees - 17.432) < 0.001)
            #expect(result.accuracyDegrees <= 25)
        }
    }

    @Test func unstablePairedOffsetsNeedAConsistentClusterBeforeChangingNorth() {
        var cache = MagneticNorthCorrectionCache()
        for (seconds, offset) in [(0.0, -10.0), (0.2, 10.0), (0.4, -10.0), (0.6, 10.0)] {
            cache.update(trueHeading: 100 + offset, magneticHeading: 100, accuracy: 20,
                         timestamp: time(seconds), location: fix(seconds), now: time(seconds))
            #expect(cache.correction(at: fix(seconds), now: time(seconds)) == nil)
        }
        feed(&cache, trueHeading: 90, magneticHeading: 100, at: 2)
        #expect(cache.correction(at: fix(2), now: time(2))?.degrees == -10)
        cache.update(trueHeading: 130, magneticHeading: 100, accuracy: 20,
                     timestamp: time(2.2), location: fix(2.2), now: time(2.2))
        #expect(cache.correction(at: fix(2.2), now: time(2.2))?.degrees == -10)
        feed(&cache, trueHeading: 130, magneticHeading: 100, at: 3)
        #expect(cache.correction(at: fix(3), now: time(3))?.degrees == 30)
    }

    @Test func invalidPhoneHeadingsNeverEstablishNorth() {
        for accuracy in [-1.0, Double.nan, Double.infinity, 181] {
            var cache = MagneticNorthCorrectionCache()
            feed(&cache, trueHeading: 90, magneticHeading: 100, accuracy: accuracy, at: 0)
            #expect(cache.correction(at: fix(), now: start) == nil)
        }
        var cache = MagneticNorthCorrectionCache()
        feed(&cache, trueHeading: -1, magneticHeading: 100, at: 0)
        #expect(cache.correction(at: fix(), now: start) == nil)
    }

    @Test func fastHeadingBurstsCanStillEstablishATimeSpanningReference() {
        var cache = MagneticNorthCorrectionCache()
        for i in 0...60 {
            let t = Double(i) / 100
            cache.update(trueHeading: 90, magneticHeading: 100, accuracy: 40,
                         timestamp: time(t), location: fix(t), now: time(t))
        }
        #expect(cache.correction(at: fix(0.6), now: time(0.6))?.degrees == -10)
    }
}
