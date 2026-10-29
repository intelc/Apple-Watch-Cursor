import XCTest
@testable import AppleWatchCursorCore

final class PointerTests: XCTestCase {
    func testVerticalSensitivityChangesOnlyYAndClampsToDisplay() {
        let offset = PointerOffset(x: 0.3, y: 0.4)
        XCTAssertEqual(offset.adjusted(verticalGain: 2, flipX: false, flipY: false), .init(x: 0.3, y: 0.8))
        XCTAssertEqual(offset.adjusted(verticalGain: 4, flipX: true, flipY: true), .init(x: -0.3, y: -1))
        XCTAssertEqual(PointerOffset.zero.adjusted(verticalGain: 4, flipX: true, flipY: true), .zero)
    }
    func testRecenterRemovesOldOffsetAndHandlesYawWrap() throws {
        var mapper = PointerMapper()
        mapper.smoothing = 0.001
        mapper.recenter(yaw: .pi-0.02, pitch: 0.4, time: 1)
        let result = try XCTUnwrap(mapper.update(yaw: -.pi+0.02, pitch: 0.4, time: 1.02))
        XCTAssertEqual(result.x, 0.1, accuracy: 0.001)
        XCTAssertEqual(result.y, 0, accuracy: 0.001)
        mapper.recenter(yaw: 1.2, pitch: -0.2, time: 2)
        XCTAssertEqual(mapper.update(yaw: 1.2, pitch: -0.2, time: 2.01), .zero)
    }

    func testOutliersAndInterruptedStreams() throws {
        var mapper = PointerMapper()
        mapper.recenter(yaw: 0, pitch: 0, time: 1)
        XCTAssertNil(mapper.update(yaw: .nan, pitch: 0, time: 1.01))
        XCTAssertNil(mapper.update(yaw: 1, pitch: 0, time: 0.9))
        XCTAssertNil(mapper.update(yaw: 1, pitch: 0, time: 2))
        XCTAssertEqual(mapper.update(yaw: 1, pitch: 0, time: 2.01), .zero)
    }
}

final class WireTests: XCTestCase {
    func testFramesFitMinimumBLEMTUAndRoundTrip() throws {
        for kind in [CommandFrame.Kind.move, .hello, .click, .recenter, .pause, .heartbeat] {
            let original = CommandFrame(kind: kind, session: 93, sequence: 100, x: -0.73, y: 0.25)
            let data = try XCTUnwrap(original.encode())
            XCTAssertLessThanOrEqual(data.count, 20)
            let decoded = try XCTUnwrap(CommandFrame(data: data))
            XCTAssertEqual(decoded.kind, kind); XCTAssertEqual(decoded.session, 93); XCTAssertEqual(decoded.sequence, 100)
            if kind != .hello {
                XCTAssertEqual(decoded.x, -0.73, accuracy: 0.00004)
                XCTAssertEqual(decoded.y, 0.25, accuracy: 0.00004)
            }
        }
        XCTAssertNil(CommandFrame(kind: .move, session: 1, sequence: 1, x: .nan).encode())
        XCTAssertNil(CommandFrame(kind: .move, session: 1, sequence: 1, x: 1.2).encode())
    }

    func testMalformedInputsNeverDecode() throws {
        XCTAssertNil(CommandFrame(data: Data(repeating: 255, count: 14)))
        let valid = try XCTUnwrap(CommandFrame(kind: .move, session: 1, sequence: 1).encode())
        for length in 0..<valid.count { XCTAssertNil(CommandFrame(data: valid.prefix(length))) }
        XCTAssertNil(CommandFrame(data: valid + Data([0])))
        var invalid = valid; invalid[10] = 0; invalid[11] = 128 // Int16.min is outside normalized range.
        XCTAssertNil(CommandFrame(data: invalid))
        let state = HostStatus(paired: true, enabled: false, accessibility: true, session: 5)
        XCTAssertEqual(HostStatus(data: state.encode()), state)
        let pending = HostStatus(session: 5, approvalPending: true)
        XCTAssertEqual(HostStatus(data: pending.encode()), pending)
        var legacy = valid; legacy[0] = 1
        XCTAssertNil(CommandFrame(data: legacy))
    }
}

final class SessionTests: XCTestCase {
    let central = UUID()
    func hello(session: UInt32 = 3) -> CommandFrame {
        .init(kind: .hello, session: session, sequence: 0)
    }
    func testPairingNeverEnablesInputAndReplayCannotTakeOver() {
        var gate = SessionGate()
        XCTAssertTrue(gate.authorize(hello(), from: central, trustedCentral: central, now: 1))
        XCTAssertFalse(gate.enabled)
        gate.setEnabled(true); XCTAssertTrue(gate.enabled)
        let move = CommandFrame(kind: .move, session: 3, sequence: 1)
        XCTAssertFalse(gate.accept(move, from: UUID(), now: 1.1))
        XCTAssertTrue(gate.accept(move, from: central, now: 1.1))
        XCTAssertFalse(gate.accept(move, from: central, now: 1.2))
        XCTAssertFalse(gate.authorize(hello(session: 4), from: UUID(), trustedCentral: central, now: 1.2))
        XCTAssertTrue(gate.accept(.init(kind: .pause, session: 3, sequence: 2), from: central, now: 1.3))
        XCTAssertFalse(gate.enabled)
    }
    func testShortGapPausesInputWithoutRevokingPairing() {
        var gate = SessionGate()
        XCTAssertTrue(gate.authorize(hello(), from: central, trustedCentral: central, now: 1))
        gate.setEnabled(true)
        XCTAssertTrue(gate.pauseIfStale(now: 2.6)); XCTAssertFalse(gate.enabled)
        XCTAssertFalse(gate.expire(now: 2.6)); XCTAssertEqual(gate.central, central)
        XCTAssertTrue(gate.accept(.init(kind: .heartbeat, session: 3, sequence: 1), from: central, now: 2.7))
        XCTAssertFalse(gate.enabled)
        gate.setEnabled(true)
        XCTAssertTrue(gate.accept(.init(kind: .move, session: 3, sequence: 2), from: central, now: 2.8))
        XCTAssertTrue(gate.enabled)
    }
    func testReturningInputCannotExecuteAfterStallEvenIfWatchdogDidNotRun() {
        var gate = SessionGate()
        XCTAssertTrue(gate.authorize(hello(), from: central, trustedCentral: central, now: 1))
        gate.setEnabled(true)
        XCTAssertTrue(gate.accept(.init(kind: .click, session: 3, sequence: 1), from: central, now: 2.7))
        XCTAssertFalse(gate.enabled)
        XCTAssertEqual(gate.central, central)
    }
    func testTrustedReconnectNeedsNoCodeAndDoesNotEnableInput() {
        var gate = SessionGate()
        XCTAssertFalse(gate.authorize(hello(), from: UUID(), trustedCentral: central, now: 1))
        XCTAssertTrue(gate.authorize(hello(), from: central, trustedCentral: central, now: 1))
        gate.setEnabled(true); gate.reset() // Actual Bluetooth disconnect.
        XCTAssertTrue(gate.authorize(hello(session: 4), from: central, trustedCentral: central, now: 2))
        XCTAssertFalse(gate.enabled)
        XCTAssertEqual(gate.session, 4)
    }
    func testFiveMinuteSessionLeaseAndDelayedFrameIdentity() {
        var gate = SessionGate()
        XCTAssertTrue(gate.authorize(hello(), from: central, trustedCentral: central, now: 1))
        let move = CommandFrame(kind: .move, session: 3, sequence: 1)
        XCTAssertTrue(gate.accept(move, from: central, now: 1.2))
        XCTAssertFalse(gate.accept(move, from: central, now: 1.3))
        XCTAssertTrue(gate.owns(move, from: central))
        XCTAssertFalse(gate.owns(move, from: UUID()))
        XCTAssertFalse(gate.expire(now: 20))
        XCTAssertTrue(gate.expire(now: 302))
        XCTAssertNil(gate.central)
    }
}

final class TapTests: XCTestCase {
    // Deliberately synthetic fixtures validate signal logic only, never recognition accuracy on people.
    func sample(_ i: Int, pulse: Double = 0, rotation: Double = 0) -> MotionSample {
        .init(time: Double(i)/100, acceleration: .init(pulse, 0, 1), rotation: .init(rotation, 0, 0), yaw: 0, pitch: 0)
    }
    func testSinglePulseDetectedOnceAndRefractorySuppressesRinging() {
        var detector = TapDetector()
        var candidates: [TapSignature] = []
        let pulses: [Int: Double] = [50: 0.10, 51: -0.06, 52: 0.03, 75: 0.08, 76: -0.04]
        for i in 0..<150 {
            let pulse = pulses[i] ?? 0
            if case .candidate(let signature) = detector.process(sample(i, pulse: pulse)) { candidates.append(signature) }
        }
        XCTAssertEqual(candidates.count, 1)
        XCTAssertTrue((0.02...0.12).contains(candidates.first?.duration ?? 0))
    }
    func testSlowWristMovementAndLargeRotationDoNotClick() {
        var detector = TapDetector()
        var count = 0
        for i in 0..<300 {
            let pulse = i == 150 ? 0.10 : sin(Double(i)/30)*0.02
            let rotation = (145...170).contains(i) ? 2.5 : 0.1
            if case .candidate = detector.process(sample(i, pulse: pulse, rotation: rotation)) { count += 1 }
        }
        XCTAssertEqual(count, 0)
    }
    func testScreenButtonAndSampleGapAreSuppressed() {
        var detector = TapDetector(); detector.suppress(until: 2)
        var count = 0
        for i in 0..<150 {
            if case .candidate = detector.process(sample(i, pulse: i == 50 ? 0.1 : 0)) { count += 1 }
        }
        _ = detector.process(sample(300, pulse: 0.1))
        for i in 301..<350 {
            if case .candidate = detector.process(sample(i)) { count += 1 }
        }
        XCTAssertEqual(count, 0)
    }
    func testProfileNeedsSixConsistentTapsAndRejectsDifferentSignature() throws {
        let signature = TapSignature(peak: 0.1, energy: 0.03, duration: 0.04, rotation: 0.15)
        XCTAssertNil(TapProfile(signatures: Array(repeating: signature, count: 5)))
        let profile = try XCTUnwrap(TapProfile(signatures: Array(repeating: signature, count: 6)))
        XCTAssertTrue(profile.matches(.init(peak: 0.11, energy: 0.032, duration: 0.05, rotation: 0.2)))
        XCTAssertFalse(profile.matches(.init(peak: 0.8, energy: 0.3, duration: 0.12, rotation: 1.4)))
        var inconsistent = Array(repeating: signature, count: 3)
        inconsistent += Array(repeating: .init(peak: 0.8, energy: 0.3, duration: 0.1, rotation: 1.4), count: 3)
        XCTAssertNil(TapProfile(signatures: inconsistent))
        let data = try JSONEncoder().encode(profile)
        XCTAssertTrue(try JSONDecoder().decode(TapProfile.self, from: data).matches(signature))
    }

    func testCalibrationAndRecognitionUseTheSameSignalPipeline() throws {
        var detector = TapDetector()
        var captures: [TapSignature] = []
        for i in 0..<750 {
            let position = i % 100
            let scale = 0.9 + Double(i/100)*0.03
            let pulse: Double = position == 50 ? 0.10*scale : position == 51 ? -0.06*scale : position == 52 ? 0.03*scale : 0
            if case .candidate(let signature) = detector.process(sample(i, pulse: pulse)) { captures.append(signature) }
        }
        XCTAssertEqual(captures.count, 7)
        let profile = try XCTUnwrap(TapProfile(signatures: Array(captures.prefix(6))))
        XCTAssertTrue(profile.matches(try XCTUnwrap(captures.last)))
    }

    func testGradualPulseOnsetDoesNotLoseQuietStateArm() {
        var detector = TapDetector()
        let ramp: [Int: Double] = [40: 0.005, 41: 0.01, 42: 0.015, 43: 0.02, 44: 0.03, 45: 0.08, 46: -0.04, 47: 0.02]
        var count = 0
        for i in 0..<120 {
            if case .candidate = detector.process(sample(i, pulse: ramp[i] ?? 0)) { count += 1 }
        }
        XCTAssertEqual(count, 1)
    }

    func testLongerRingingPulseFinishesAfterSettling() throws {
        var detector = TapDetector()
        var signatures: [TapSignature] = []
        for i in 0..<150 {
            let pulse = (50...75).contains(i) ? (i.isMultiple(of: 2) ? 1.0 : -1.0) * 0.1 * exp(-Double(i-50)/25) : 0
            if case .candidate(let signature) = detector.process(sample(i, pulse: pulse)) { signatures.append(signature) }
        }
        XCTAssertEqual(signatures.count, 1)
        XCTAssertGreaterThan(try XCTUnwrap(signatures.first).duration, 0.14)
    }

    func testGuidedTrainingUsesRestAndSixCuesAndRejectsFalseRestEvent() throws {
        let cues = [3.0, 4.5, 6.0, 7.5, 9.0, 10.5]
        func recording(extraTap: Bool) -> [MotionSample] {
            (0...1200).map { i in
                let starts = (cues.map { Int(($0+0.3)*100) } + (extraTap ? [255] : [])).sorted()
                let start = starts.last(where: { i >= $0 })
                let offset = start.map { i-$0 } ?? 100
                let pulse = (0...25).contains(offset) ? (i.isMultiple(of: 2) ? 1.0 : -1.0) * 0.1 * exp(-Double(offset)/25) : 0
                return sample(i, pulse: pulse)
            }
        }
        let samples = recording(extraTap: false)
        let calibration = try XCTUnwrap(GuidedTapTrainer.train(samples: samples, cueTimes: cues))
        XCTAssertTrue(calibration.isValid)
        var detector = TapDetector(); detector.threshold = calibration.threshold
        var count = 0
        for item in samples {
            if case .candidate(let signature) = detector.process(item), calibration.profile.matches(signature) { count += 1 }
        }
        XCTAssertEqual(count, 6)
        XCTAssertNil(GuidedTapTrainer.train(samples: samples, cueTimes: Array(cues.prefix(5))))
        XCTAssertNil(GuidedTapTrainer.train(samples: (0...1200).map { sample($0) }, cueTimes: cues))
        XCTAssertNil(GuidedTapTrainer.train(samples: recording(extraTap: true), cueTimes: cues))
    }
}
