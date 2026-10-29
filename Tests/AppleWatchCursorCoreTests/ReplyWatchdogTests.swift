import XCTest
@testable import AppleWatchCursorCore

final class ReplyWatchdogTests: XCTestCase {
    func testWakeTimerBeforeQueuedReplyDoesNotPauseOrReconnect() {
        var watchdog = ReplyWatchdog(); watchdog.resume(now: 0)
        for step in 0...12 { _ = watchdog.tick(now: Double(step)*0.5, interactive: true) }
        // Real log: a delayed timer ran just before a valid reply after wrist wake.
        XCTAssertEqual(watchdog.tick(now: 18.7, interactive: true), .resuming)
        watchdog.receivedReply(now: 18.72)
        for step in 1...6 {
            XCTAssertEqual(watchdog.tick(now: 18.7+Double(step)*0.5, interactive: true), step < 6 ? .resuming : .healthy)
        }
    }

    func testInactiveDisplayNeverCausesAnAppInitiatedDisconnect() {
        var watchdog = ReplyWatchdog(); watchdog.resume(now: 0)
        for step in 0...80 {
            XCTAssertEqual(watchdog.tick(now: Double(step)*0.5, interactive: false), .resuming)
        }
        XCTAssertEqual(watchdog.tick(now: 40.5, interactive: true), .resuming)
        watchdog.receivedReply(now: 40.6)
        for step in 1...6 { _ = watchdog.tick(now: 40.5+Double(step)*0.5, interactive: true) }
        XCTAssertEqual(watchdog.tick(now: 44, interactive: true), .healthy)
    }

    func testGenuineUnresponsiveLinkDetectedDuringContinuousActivePolling() {
        var watchdog = ReplyWatchdog(); watchdog.resume(now: 0)
        for step in 0...16 { _ = watchdog.tick(now: Double(step)*0.5, interactive: true) }
        XCTAssertEqual(watchdog.tick(now: 8.5, interactive: true), .delayed)
        for step in 18...30 { _ = watchdog.tick(now: Double(step)*0.5, interactive: true) }
        XCTAssertEqual(watchdog.tick(now: 15.5, interactive: true), .unresponsive)
    }

    func testWriteReplyRestoresHealthWithoutDependingOnStatusRead() {
        var watchdog = ReplyWatchdog(); watchdog.resume(now: 0)
        for step in 0...17 { _ = watchdog.tick(now: Double(step)*0.5, interactive: true) }
        watchdog.receivedReply(now: 8.6)
        XCTAssertEqual(watchdog.tick(now: 9, interactive: true), .healthy)
    }
}
