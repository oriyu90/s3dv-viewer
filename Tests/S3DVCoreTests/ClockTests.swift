import XCTest
@testable import S3DVCore

/// Pacing math parity with server.py: min(2, max(0, (ts-prev)/1e9/rate)).
final class ClockTests: XCTestCase {
    func testOneSecondGapAtRateOne() {
        XCTAssertEqual(ReplayClock.pacingDelay(prevTS: 0, ts: 1_000_000_000, rate: 1), 1.0)
    }

    func testRateScalesDelay() {
        XCTAssertEqual(ReplayClock.pacingDelay(prevTS: 0, ts: 1_000_000_000, rate: 4), 0.25)
        XCTAssertEqual(ReplayClock.pacingDelay(prevTS: 0, ts: 250_000_000, rate: 0.25), 1.0)
        XCTAssertEqual(ReplayClock.pacingDelay(prevTS: 0, ts: 500_000_000, rate: 0.25),
                       ReplayClock.maxDelay) // 2.0 s span hits the cap
    }

    func testTwoSecondCapIsApplied() {
        XCTAssertEqual(ReplayClock.pacingDelay(prevTS: 0, ts: 5_000_000_000, rate: 1), ReplayClock.maxDelay)
        XCTAssertEqual(ReplayClock.pacingDelay(prevTS: 0, ts: 10_000_000_000, rate: 0.5),
                       ReplayClock.maxDelay)
    }

    func testBackwardsTimestampClampsToZero() {
        XCTAssertEqual(ReplayClock.pacingDelay(prevTS: 5_000_000_000, ts: 1_000, rate: 1), 0)
    }

    func testZeroGapClampsToZero() {
        XCTAssertEqual(ReplayClock.pacingDelay(prevTS: 1_000_000, ts: 1_000_000, rate: 1), 0)
    }

    func testNonpositiveRateYieldsZero() {
        XCTAssertEqual(ReplayClock.pacingDelay(prevTS: 0, ts: 1_000_000_000, rate: 0), 0)
        XCTAssertEqual(ReplayClock.pacingDelay(prevTS: 0, ts: 1_000_000_000, rate: -1), 0)
    }
}
