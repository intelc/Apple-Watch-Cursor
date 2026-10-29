import XCTest
@testable import AppleWatchCursorCore

final class TapFeedbackTests: XCTestCase {
    func testPracticeCountsEveryReceivedTapWhilePausedAndWithoutMotion() {
        var feedback = TapFeedback()
        for time in [1.0, 1.1, 2.0] {
            XCTAssertEqual(feedback.receive(now: time, enabled: false, practiceOnly: true,
                                            hasPermission: false, lastMotion: nil), .practice)
        }
        XCTAssertEqual(feedback.receivedCount, 3)
    }

    func testLiveClickGuardsDoNotHideReceivedTapFeedback() {
        var feedback = TapFeedback()
        XCTAssertEqual(feedback.receive(now: 1, enabled: false, practiceOnly: false,
                                        hasPermission: true, lastMotion: 0.9), .paused)
        XCTAssertEqual(feedback.receive(now: 1.1, enabled: true, practiceOnly: false,
                                        hasPermission: false, lastMotion: 1), .permissionRequired)
        XCTAssertEqual(feedback.receive(now: 2, enabled: true, practiceOnly: false,
                                        hasPermission: true, lastMotion: 1), .staleMotion)
        XCTAssertEqual(feedback.receive(now: 2.1, enabled: true, practiceOnly: false,
                                        hasPermission: true, lastMotion: 3), .staleMotion)
        XCTAssertEqual(feedback.receivedCount, 4)
    }

    func testOnlyFreshEnabledLiveInputClicksAndRateLimitStillApplies() {
        var feedback = TapFeedback()
        XCTAssertEqual(feedback.receive(now: 1, enabled: true, practiceOnly: false,
                                        hasPermission: true, lastMotion: 0.9), .liveClick)
        XCTAssertEqual(feedback.receive(now: 1.1, enabled: true, practiceOnly: false,
                                        hasPermission: true, lastMotion: 1.05), .rateLimited)
        XCTAssertEqual(feedback.receive(now: 1.4, enabled: true, practiceOnly: false,
                                        hasPermission: true, lastMotion: 1.3), .liveClick)
        XCTAssertEqual(feedback.receivedCount, 3)
    }
}
