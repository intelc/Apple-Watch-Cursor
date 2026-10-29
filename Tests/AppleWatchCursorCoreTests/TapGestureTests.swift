import XCTest
@testable import AppleWatchCursorCore

final class TapGestureTests: XCTestCase {
    func testSingleWaitsForDoubleTapWindowThenEmitsOnce() {
        var gesture = TapGestureRecognizer()
        XCTAssertNil(gesture.recognized(time: 1))
        XCTAssertNil(gesture.poll(time: 1.49))
        XCTAssertEqual(gesture.poll(time: 1.51), .singleClick)
        XCTAssertNil(gesture.poll(time: 2))
    }
    func testDoubleConsumesBothTapsAndNeverEmitsClick() {
        var gesture = TapGestureRecognizer()
        XCTAssertNil(gesture.recognized(time: 1))
        gesture.began(time: 1.3)
        XCTAssertEqual(gesture.recognized(time: 1.45), .toggleControl)
        XCTAssertNil(gesture.poll(time: 2))
        XCTAssertFalse(gesture.hasPendingTap)
    }
    func testSecondPulseCanSettleBeyondWindowWithoutLeakingFirstClick() {
        var gesture = TapGestureRecognizer()
        _ = gesture.recognized(time: 1)
        gesture.began(time: 1.4)
        XCTAssertNil(gesture.poll(time: 1.6))
        XCTAssertEqual(gesture.recognized(time: 1.7), .toggleControl)
    }
    func testRejectedSecondPulseReleasesOnlyTheOriginalSingle() {
        var gesture = TapGestureRecognizer()
        _ = gesture.recognized(time: 1); gesture.began(time: 1.4)
        XCTAssertEqual(gesture.rejected(time: 1.7), .singleClick)
        XCTAssertNil(gesture.poll(time: 2))
    }
    func testSeparatedTapsDoNotBecomeToggle() {
        var gesture = TapGestureRecognizer()
        _ = gesture.recognized(time: 1)
        XCTAssertEqual(gesture.recognized(time: 2), .singleClick)
        XCTAssertEqual(gesture.poll(time: 2.6), .singleClick)
    }
    func testResetOnPauseOrSensorGapDropsPendingClickAndPartialDouble() {
        var gesture = TapGestureRecognizer()
        _ = gesture.recognized(time: 1); gesture.began(time: 1.4); gesture.reset()
        XCTAssertNil(gesture.poll(time: 4))
        XCTAssertNil(gesture.recognized(time: 4.1))
        XCTAssertNil(gesture.poll(time: .nan))
    }
    func testThirdTapAndModeFeedbackCannotCauseClickAfterToggle() {
        var gesture = TapGestureRecognizer()
        _ = gesture.recognized(time: 1)
        XCTAssertEqual(gesture.recognized(time: 1.4), .toggleControl)
        gesture.cancelPending() // Host mode acknowledgement arrives.
        XCTAssertNil(gesture.recognized(time: 1.8))
        XCTAssertNil(gesture.poll(time: 2.4))
    }
    func testHighRateDetectorCanRecognizeTwoDeliberateTapsForModeGesture() {
        var detector = TapDetector(); detector.refractoryPeriod = 0.12
        var count = 0
        let pulses: [Int: Double] = [50: 0.10,51: -0.06,52: 0.03,95: 0.10,96: -0.06,97: 0.03]
        for i in 0..<160 {
            let sample = MotionSample(time: Double(i)/100,acceleration: .init(pulses[i] ?? 0,0,1),rotation: .init(0,0,0),yaw: 0,pitch: 0)
            if case .candidate = detector.process(sample) { count += 1 }
        }
        XCTAssertEqual(count,2)
    }
    func testMouseEntryNeedsCalibrationPermissionAndFreshMotion() {
        func block(paired: Bool = true, calibrated: Bool = true, calibrating: Bool = false,
                   permission: Bool = true, practice: Bool = false, age: Double? = 0.1) -> MouseControlPolicy.Block? {
            MouseControlPolicy.block(paired: paired,calibrated: calibrated,calibrating: calibrating,
                                     permission: permission,practice: practice,motionAge: age)
        }
        XCTAssertEqual(block(paired: false), .connection)
        XCTAssertEqual(block(calibrated: false), .calibration)
        XCTAssertEqual(block(calibrating: true), .calibrating)
        XCTAssertEqual(block(permission: false), .permission)
        XCTAssertEqual(block(age: nil), .motion)
        XCTAssertEqual(block(age: 0.5), .motion)
        XCTAssertEqual(block(age: -1), .motion)
        XCTAssertNil(block())
        XCTAssertNil(block(permission: false,practice: true))
    }
    func testGestureCommandsAndArmedStatusRoundTrip() throws {
        let status = HostStatus(paired: true,enabled: false,session: 5,gesturesArmed: true)
        XCTAssertEqual(HostStatus(data: status.encode()), status)
        for kind in [CommandFrame.Kind.singleClick,.toggleControl] {
            let data = try XCTUnwrap(CommandFrame(kind: kind,session: 5,sequence: 1,x: 0.3,y: -0.2).encode())
            XCTAssertEqual(CommandFrame(data: data)?.kind,kind)
            XCTAssertLessThanOrEqual(data.count,20)
        }
    }
}
