import XCTest
@testable import AppleWatchCursorCore

final class AxisCalibrationTests: XCTestCase {
    func train(_ h: PointerOffset, _ v: PointerOffset, neutral n: PointerOffset = .zero) throws -> AxisCalibrationProfile {
        try .train(neutral: n, right: .init(x: PointerMapper.wrap(n.x+h.x), y: n.y+h.y),
                   left: .init(x: PointerMapper.wrap(n.x-h.x), y: n.y-h.y),
                   up: .init(x: PointerMapper.wrap(n.x-v.x), y: n.y-v.y),
                   down: .init(x: PointerMapper.wrap(n.x+v.x), y: n.y+v.y))
    }
    func testLearnsFlippedMixedAxesAndUnequalComfortableRanges() throws {
        let h = PointerOffset(x: -0.24, y: 0.06), v = PointerOffset(x: 0.04, y: 0.12)
        let profile = try train(h,v)
        XCTAssertTrue(profile.isValid)
        XCTAssertEqual(profile.map(h).x, 1, accuracy: 0.00001)
        XCTAssertEqual(profile.map(h).y, 0, accuracy: 0.00001)
        XCTAssertEqual(profile.map(v).x, 0, accuracy: 0.00001)
        XCTAssertEqual(profile.map(v).y, 1, accuracy: 0.00001)
        let diagonal = profile.map(.init(x: (h.x+v.x)/2, y: (h.y+v.y)/2))
        XCTAssertEqual(diagonal.x, 0.5, accuracy: 0.00001)
        XCTAssertEqual(diagonal.y, 0.5, accuracy: 0.00001)
        XCTAssertEqual(profile.map(.zero), .zero)
        XCTAssertEqual(try JSONDecoder().decode(AxisCalibrationProfile.self, from: JSONEncoder().encode(profile)), profile)
    }
    func testYawCrossingPiStillLearnsSameMapping() throws {
        let h = PointerOffset(x: 0.2,y: 0.01), v = PointerOffset(x: 0.03,y: 0.14)
        let profile = try train(h,v,neutral: .init(x: .pi-0.05,y: -0.3))
        XCTAssertEqual(profile.map(h).x, 1, accuracy: 0.00001)
        XCTAssertEqual(profile.map(v).y, 1, accuracy: 0.00001)
    }
    func testRejectsInsufficientAndIndistinguishableDirections() {
        XCTAssertThrowsError(try train(.init(x: 0.01,y: 0),.init(x: 0,y: 0.1)))
        XCTAssertThrowsError(try train(.init(x: 0.2,y: 0),.init(x: 0.19,y: 0.01)))
        XCTAssertThrowsError(try AxisCalibrationProfile.train(neutral: .zero,
            right: .init(x: 0.2,y: 0),left: .init(x: 0.15,y: 0),
            up: .init(x: 0,y: -0.2),down: .init(x: 0,y: 0.2)))
        XCTAssertThrowsError(try AxisCalibrationProfile.train(neutral: .zero,
            right: .init(x: 0.4,y: 0),left: .init(x: -0.1,y: 0),
            up: .init(x: 0,y: -0.2),down: .init(x: 0,y: 0.2)))
    }
    func testStableCaptureRequiresFreshContinuousStillSamples() throws {
        var window = StablePoseWindow()
        for i in 0..<24 { window.append(time: Double(i)/40,pose: .init(x: 0.2,y: -0.1)) }
        let mean = try XCTUnwrap(window.mean(now: 0.6))
        XCTAssertEqual(mean.x, 0.2, accuracy: 0.00001)
        XCTAssertEqual(mean.y, -0.1, accuracy: 0.00001)
        XCTAssertNil(window.mean(now: 1))
        window.append(time: 2,pose: .zero)
        XCTAssertNil(window.mean(now: 2.01))
        window.reset()
        for i in 0..<24 { window.append(time: Double(i)/40,pose: .init(x: Double(i)*0.005,y: 0)) }
        XCTAssertNil(window.mean(now: 0.6))
    }
    func testStableCaptureUsesCircularYawMean() throws {
        var window = StablePoseWindow()
        for i in 0..<24 { window.append(time: Double(i)/40,pose: .init(x: i.isMultiple(of: 2) ? .pi-0.001 : -.pi+0.001,y: 0)) }
        XCTAssertEqual(abs(try XCTUnwrap(window.mean(now: 0.6)).x), .pi, accuracy: 0.00001)
    }
    func testCaptureReadinessExplainsMissingStaleMovingAndReadyData() {
        var window = StablePoseWindow()
        XCTAssertEqual(window.readiness(now: 0), .noData)
        window.append(time: 0,pose: .zero)
        XCTAssertEqual(window.readiness(now: 0.01), .collecting)
        for i in 1..<24 { window.append(time: Double(i)/40,pose: .zero) }
        XCTAssertEqual(window.readiness(now: 0.6), .ready)
        XCTAssertEqual(window.readiness(now: 1), .stale)
        window.reset()
        for i in 0..<24 { window.append(time: Double(i)/40,pose: .init(x: Double(i)*0.005,y: 0)) }
        XCTAssertEqual(window.readiness(now: 0.6), .moving)
    }
    func testCalibrationRequestAndNewMotionCommandsRoundTripWithinMinimumMTU() throws {
        let status = HostStatus(paired: true,session: 42,axisCalibrationRequest: 255)
        XCTAssertEqual(status.encode().count,7)
        XCTAssertEqual(HostStatus(data: status.encode()),status)
        XCTAssertEqual(HostStatus(data: HostStatus(paired: true,session: 42).encode())?.axisCalibrationRequest,0)
        for kind in [CommandFrame.Kind.axisSample,.angularMove,.axisCalibrationReady] {
            let data = try XCTUnwrap(CommandFrame(kind: kind,session: 42,sequence: 3,x: -0.7,y: 0.3).encode())
            XCTAssertLessThanOrEqual(data.count,20)
            XCTAssertEqual(CommandFrame(data: data)?.kind,kind)
        }
        for token in 1...255 {
            let data = try XCTUnwrap(CommandFrame(kind: .axisCalibrationReady,session: 42,sequence: 3,x: Double(token)/255).encode())
            XCTAssertEqual(Int((try XCTUnwrap(CommandFrame(data: data)).x*255).rounded()),token)
        }
    }
    func testAngularTransportPreservesWiderRangesBeforePersonalMapping() throws {
        var mapper = PointerMapper()
        mapper.horizontalRange = .pi; mapper.verticalRange = .pi; mapper.smoothing = 0.001
        mapper.recenter(yaw: 0,pitch: 0,time: 1)
        let offset = try XCTUnwrap(mapper.update(yaw: 0.8,pitch: 0.6,time: 1.02))
        XCTAssertEqual(offset.x * .pi,0.8,accuracy: 0.00001)
        XCTAssertEqual(offset.y * .pi,-0.6,accuracy: 0.00001)
    }
    func testAngularAndCalibrationSamplesCoalesceWithoutWaitingForHeartbeat() {
        for kind in [CommandFrame.Kind.angularMove,.axisSample] {
            var queue = OutboundBuffer()
            _ = queue.enqueue(.init(kind: .heartbeat)); _ = queue.next(canSendMovement: true)
            _ = queue.enqueue(.init(kind: kind,x: 0.1)); _ = queue.enqueue(.init(kind: kind,x: 0.8))
            XCTAssertEqual(queue.next(canSendMovement: true),.init(kind: kind,x: 0.8))
            XCTAssertNil(queue.next(canSendMovement: true))
        }
    }
}
