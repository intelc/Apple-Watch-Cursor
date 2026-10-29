import XCTest
@testable import AppleWatchCursorCore

final class OrientationTests: XCTestCase {
    func near(_ a: Vector3,_ b: Vector3,file: StaticString = #filePath,line: UInt = #line) {
        XCTAssertEqual(a.x,b.x,accuracy: 0.0001,file: file,line: line)
        XCTAssertEqual(a.y,b.y,accuracy: 0.0001,file: file,line: line)
        XCTAssertEqual(a.z,b.z,accuracy: 0.0001,file: file,line: line)
    }
    func sweeps(h: Vector3 = .init(0.6,0,0.4),v: Vector3 = .init(-0.6,0,0.4),base: Quaternion = .identity) -> [SweepDirection: OrientationSweep] {
        func pose(_ v: Vector3) -> Quaternion { Quaternion.fromRotationVector(v)*base }
        return [.topDown: .init(start: pose(v * -0.5),end: pose(v * 0.5),duration: 1),
                .bottomUp: .init(start: pose(v * 0.5),end: pose(v * -0.5),duration: 1),
                .leftRight: .init(start: pose(h * -0.5),end: pose(h * 0.5),duration: 1),
                .rightLeft: .init(start: pose(h * 0.5),end: pose(h * -0.5),duration: 1)]
    }
    func testQuaternionLogAndSignEquivalentOrientations() throws {
        let v = Vector3(0.3,-0.2,0.6), q = Quaternion.fromRotationVector(v)
        near(try XCTUnwrap(Quaternion.identity.rotation(to: q)),v)
        XCTAssertEqual(try XCTUnwrap(q.distance(to: .init(-q.x,-q.y,-q.z,-q.w))),0,accuracy: 0.00001)
        XCTAssertNil(Quaternion(0,0,0,0).unit)
        XCTAssertNil(Quaternion(.nan,0,0,1).unit)
    }
    func testRollSeparatesAxesWithCollinearTwoComponentProjection() throws {
        let profile = try OrientationCalibrationProfile.train(sweeps())
        let right = profile.map(.init(0.3,0,0.2)), down = profile.map(.init(-0.3,0,0.2))
        XCTAssertEqual(right.x,1,accuracy: 0.0001); XCTAssertEqual(right.y,0,accuracy: 0.0001)
        XCTAssertEqual(down.x,0,accuracy: 0.0001); XCTAssertEqual(down.y,1,accuracy: 0.0001)
        XCTAssertEqual(try JSONDecoder().decode(OrientationCalibrationProfile.self,from: JSONEncoder().encode(profile)),profile)
    }
    func testReferenceFrameRestartDoesNotChangeBodyRelativeCalibration() throws {
        let base = Quaternion.fromRotationVector(.init(0.4,-0.2,0.6))
        let original = sweeps(base: base), change = Quaternion.fromRotationVector(.init(0,0,1.1))
        let changed = original.mapValues { OrientationSweep(start: $0.start*change,end: $0.end*change,duration: $0.duration) }
        let a = try OrientationCalibrationProfile.train(original), b = try OrientationCalibrationProfile.train(changed)
        near(a.horizontal,b.horizontal); near(a.vertical,b.vertical)
        let current = Quaternion.fromRotationVector(.init(0.2,0,0.1))*base
        near(try XCTUnwrap(base.rotation(to: current)),try XCTUnwrap((base*change).rotation(to: current*change)))
    }
    func testTrueParallelAndWrongReverseStillRejectedIn3D() {
        XCTAssertThrowsError(try OrientationCalibrationProfile.train(sweeps(h: .init(0.3,0.3,0),v: .init(0.6,0.6,0))))
        var wrong = sweeps(); wrong[.bottomUp] = wrong[.topDown]
        XCTAssertThrowsError(try OrientationCalibrationProfile.train(wrong))
    }
    func testElbowCenteredArcWithGentleWristCompensationIsDetected() throws {
        var detector = OrientationSweepDetector(), found: [OrientationSweep] = []
        let base = Quaternion.fromRotationVector(.init(0.8,-0.4,0.3))
        for i in 0..<150 {
            let t = min(1,max(0,Double(i-30)/45))
            let elbow = Quaternion.fromRotationVector(.init(0,0,(t-0.5)*0.8))
            let wrist = Quaternion.fromRotationVector(.init(0.06*sin(t * .pi),0,0))
            let pose = wrist*elbow*base
            if case .completed(let sweep) = detector.process(time: Double(i)/30,pose: pose) { found.append(sweep) }
        }
        XCTAssertEqual(found.count,1)
        XCTAssertEqual(try XCTUnwrap(found.first?.start.distance(to: found.first!.end)),0.8,accuracy: 0.02)
    }
    func test3DDetectorRejectsStillnessAndGapsAndWaitsForReverseStart() {
        var detector = OrientationSweepDetector(expectedStart: Quaternion.fromRotationVector(.init(0.4,0,0)))
        for i in 0..<30 { XCTAssertNil(detector.process(time: Double(i)/30,pose: .identity)) }
        var ready = false
        for i in 30..<60 {
            if case .ready = detector.process(time: Double(i)/30,pose: .fromRotationVector(.init(0.4,0,0))) { ready = true }
        }
        XCTAssertTrue(ready)
        XCTAssertEqual(detector.process(time: 4,pose: .identity),.interrupted)
        for i in 1..<30 { XCTAssertNotEqual(detector.process(time: 4+Double(i)/30,pose: .identity),.ready) }
    }
    func testQuaternionMeanStaysStableAcrossSignFlips() throws {
        var window = OrientationWindow()
        let q = Quaternion.fromRotationVector(.init(0.2,0.3,0.4))
        for i in 0..<24 {
            let pose = i.isMultiple(of: 2) ? q : Quaternion(-q.x,-q.y,-q.z,-q.w)
            window.append(time: Double(i)/40,pose: pose)
        }
        let mean = try XCTUnwrap(window.mean(now: 0.6))
        XCTAssertLessThan(try XCTUnwrap(mean.distance(to: q)),0.00001)
        XCTAssertNil(window.mean(now: 1))
    }
    func testOrientationAndLegacyTargetFitExactlyTwentyBytes() throws {
        for i in 0..<250 {
            let v = Vector3(sin(Double(i)*0.3)*2,cos(Double(i)*0.7)*2,sin(Double(i)*0.9)*2)
            let q = Quaternion.fromRotationVector(v)
            for kind in [CommandFrame.Kind.pose,.axisPose,.singleClick,.recenter] {
                let frame = CommandFrame(kind: kind,session: 7,sequence: UInt32(i+1),x: -0.3,y: 0.4,orientation: q)
                let data = try XCTUnwrap(frame.encode())
                XCTAssertEqual(data.count,20)
                let decoded = try XCTUnwrap(CommandFrame(data: data))
                XCTAssertEqual(decoded.kind,kind)
                XCTAssertEqual(decoded.x,-0.3,accuracy: 0.00004)
                XCTAssertEqual(decoded.y,0.4,accuracy: 0.00004)
                XCTAssertLessThan(try XCTUnwrap(q.distance(to: try XCTUnwrap(decoded.orientation))),0.0002)
            }
        }
    }
    func testMalformedOrientationPacketsCannotDecode() throws {
        XCTAssertNil(CommandFrame(kind: .pose,session: 1,sequence: 1).encode())
        XCTAssertNil(CommandFrame(kind: .hello,session: 1,sequence: 1,orientation: .identity).encode())
        var data = try XCTUnwrap(CommandFrame(kind: .pose,session: 1,sequence: 1,orientation: .identity).encode())
        data[14]=0; data[15]=128
        XCTAssertNil(CommandFrame(data: data))
        for i in stride(from: 14,to: 20,by: 2) { data[i]=255; data[i+1]=127 }
        XCTAssertNil(CommandFrame(data: data))
        let status = HostStatus(paired: true,session: 7,gesturesArmed: true,supportsOrientation: true)
        XCTAssertEqual(HostStatus(data: status.encode()),status)
    }
    func testPoseCoalescingAndAuthenticatedSessionSupportFullPacket() throws {
        var queue = OutboundBuffer()
        _ = queue.enqueue(.init(kind: .pose,x: 0.1,orientation: .identity))
        let q = Quaternion.fromRotationVector(.init(0.2,0.1,0))
        _ = queue.enqueue(.init(kind: .pose,x: 0.3,orientation: q))
        let next = try XCTUnwrap(queue.next(canSendMovement: true))
        XCTAssertEqual(next.orientation,q); XCTAssertEqual(next.x,0.3)
        let central=UUID(); var gate=SessionGate()
        XCTAssertTrue(gate.authorize(.init(kind: .hello,session: 7,sequence: 0),from: central,trustedCentral: central,now: 1))
        let decoded = try XCTUnwrap(CommandFrame(data: try XCTUnwrap(CommandFrame(kind: .pose,session: 7,sequence: 1,orientation: q).encode())))
        XCTAssertTrue(gate.accept(decoded,from: central,now: 1.1))
        XCTAssertFalse(gate.enabled)
    }
    func testLegacyTapRecordingWithoutQuaternionStillDecodes() throws {
        let json = #"{"time":1,"acceleration":{"x":0,"y":0,"z":1},"rotation":{"x":0,"y":0,"z":0},"yaw":0,"pitch":0}"#
        let sample = try JSONDecoder().decode(MotionSample.self,from: Data(json.utf8))
        XCTAssertNil(sample.orientation)
        XCTAssertTrue(sample.isFinite)
    }
}
