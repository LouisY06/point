import Foundation
import Testing
@testable import PointCore

@MainActor struct PhoneHapticWorkerTests {
    @Test func slowHardwareDoesNotBlockUIOrReplayQueuedDirections() async throws {
        let probe = SlowOutputProbe()
        let worker = PhoneHapticWorker { _ in SlowPhoneOutput(probe: probe) }
        let session = UUID()
        worker.submit(.intensity(0.8), session: session)
        let started = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: probe.started.wait(timeout: .now() + 2) == .success)
            }
        }
        #expect(started)
        defer { probe.release.signal() }
        // Release even if a regression accidentally makes submit wait on the hardware.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { probe.release.signal() }
        let before = ProcessInfo.processInfo.systemUptime
        for _ in 0..<1_000 { worker.submit(.intensity(0.8), session: session) }
        worker.submit(.silence, session: session)
        #expect(ProcessInfo.processInfo.systemUptime - before < 0.5)
        #expect(probe.counts.bursts == 0)
        #expect(worker.snapshot.submittedIntensity == 0)
        #expect(!probe.counts.usedMainThread)

        probe.release.signal()
        // Wait for startup to finish; silence superseded all 1,001 old requests.
        for _ in 0..<100 {
            if probe.counts.prepared { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(probe.counts.bursts == 0)
        worker.submit(.intensity(0.6), session: session)
        for _ in 0..<100 {
            if worker.snapshot.submittedIntensity > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(probe.counts.bursts == 1)
        #expect(worker.snapshot.submittedIntensity == 0.6)
        worker.submit(.shutdown, session: UUID())
        #expect(worker.snapshot.submittedIntensity == 0)
    }
}

private final class SlowOutputProbe: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var state = (bursts: 0, usedMainThread: false, prepared: false)
    var counts: (bursts: Int, usedMainThread: Bool, prepared: Bool) {
        lock.lock(); defer { lock.unlock() }; return state
    }
    func preparing() {
        lock.lock(); state.usedMainThread = Thread.isMainThread; lock.unlock()
        started.signal()
        _ = release.wait(timeout: .now() + 3)
        lock.lock(); state.prepared = true; lock.unlock()
    }
    func burst() { lock.lock(); state.bursts += 1; lock.unlock() }
}

private final class SlowPhoneOutput: PhoneHapticOutput {
    let probe: SlowOutputProbe
    init(probe: SlowOutputProbe) { self.probe = probe }
    func prepare(onInterruption: @escaping (PhoneHapticInterruption) -> Void) throws { probe.preparing() }
    func startBurst(intensity: Double, duration: TimeInterval) throws { probe.burst() }
    func changeIntensity(_ intensity: Double) throws {}
    func silence() {}
    func shutdown() {}
}
