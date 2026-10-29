import XCTest
@testable import AppleWatchCursorCore

final class SweepCalibrationTests: XCTestCase {
    func trace(delta: PointerOffset, start: PointerOffset = .zero) -> [SweepDetector.Event] {
        var detector = SweepDetector()
        var events: [SweepDetector.Event] = []
        for i in 0..<120 {
            let progress = min(1,max(0,Double(i-30)/30))
            let pose = PointerOffset(x: PointerMapper.wrap(start.x+delta.x*progress),y: start.y+delta.y*progress)
            if let event = detector.process(time: Double(i)/30,pose: pose) { events.append(event) }
        }
        return events
    }
    func testSteadyStartSweepAndFinishAreDetectedOnceWithoutKeys() throws {
        let events = trace(delta: .init(x: 0.05,y: 0.4))
        XCTAssertEqual(events.filter { $0 == .ready }.count,1)
        XCTAssertEqual(events.filter { $0 == .moving }.count,1)
        let sweeps = events.compactMap { event -> SweepMeasurement? in
            if case .completed(let m) = event { return m }; return nil
        }
        XCTAssertEqual(sweeps.count,1)
        let sweep = try XCTUnwrap(sweeps.first)
        XCTAssertEqual(sweep.delta.x,0.05,accuracy: 0.005)
        XCTAssertEqual(sweep.delta.y,0.4,accuracy: 0.01)
    }
    func testStillnessAndTinyMovementDoNotProduceCheckmark() {
        for delta in [PointerOffset.zero,.init(x: 0.02,y: -0.03)] {
            XCTAssertFalse(trace(delta: delta).contains { if case .completed = $0 { return true }; return false })
        }
    }
    func testSleepGapCannotBeMistakenForSweep() {
        var detector = SweepDetector()
        for i in 0..<25 { _ = detector.process(time: Double(i)/30,pose: .zero) }
        XCTAssertEqual(detector.process(time: 2,pose: .init(x: 0.4,y: 0)),.interrupted)
        for i in 1..<35 {
            if case .completed = detector.process(time: 2+Double(i)/30,pose: .init(x: 0.4,y: 0)) {
                XCTFail("A position jump across a suspension is not a sweep")
            }
        }
    }
    func testSweepCanCrossYawWrap() throws {
        let measurements = trace(delta: .init(x: 0.4,y: 0),start: .init(x: .pi-0.2,y: 0)).compactMap { event -> SweepMeasurement? in
            if case .completed(let m) = event { return m }; return nil
        }
        XCTAssertEqual(try XCTUnwrap(measurements.first).delta.x,0.4,accuracy: 0.01)
    }
    func measurements() -> [SweepDirection: SweepMeasurement] {
        [.topDown: .init(delta: .init(x: 0.08,y: 0.32),duration: 1),
         .bottomUp: .init(delta: .init(x: -0.08,y: -0.32),duration: 1),
         .leftRight: .init(delta: .init(x: -0.5,y: 0.06),duration: 1),
         .rightLeft: .init(delta: .init(x: 0.5,y: -0.06),duration: 1)]
    }
    func testFourLabeledSweepsLearnReversedMixedAxesAndComfortableRange() throws {
        let mapping = try SweepCalibration.train(measurements())
        let right = mapping.map(.init(x: -0.25,y: 0.03))
        let down = mapping.map(.init(x: 0.04,y: 0.16))
        XCTAssertEqual(right.x,1,accuracy: 0.0001); XCTAssertEqual(right.y,0,accuracy: 0.0001)
        XCTAssertEqual(down.x,0,accuracy: 0.0001); XCTAssertEqual(down.y,1,accuracy: 0.0001)
    }
    func testWrongReverseAndParallelHorizontalSweepAreRejected() {
        let good = measurements()
        XCTAssertThrowsError(try SweepCalibration.validate(good[.topDown]!,direction: .bottomUp,previous: good))
        XCTAssertThrowsError(try SweepCalibration.validate(good[.topDown]!,direction: .leftRight,previous: good))
        var missing = good; missing.removeValue(forKey: .rightLeft)
        XCTAssertThrowsError(try SweepCalibration.train(missing))
    }
    func testReturningToStartIsNotAnEndToEndSweep() {
        var detector = SweepDetector()
        var completed = 0
        for i in 0..<140 {
            let x: Double
            if i < 30 { x = 0 }
            else if i < 45 { x = Double(i-30)*0.025 }
            else if i < 60 { x = Double(60-i)*0.025 }
            else { x = 0 }
            if case .completed = detector.process(time: Double(i)/30,pose: .init(x: x,y: 0)) { completed += 1 }
        }
        XCTAssertEqual(completed,0)
    }
    func testReverseWaitsForThePreviouslyLearnedEndpoint() throws {
        var detector = SweepDetector(expectedStart: .init(x: 0.4,y: 0),startTolerance: 0.06)
        var measurements: [SweepMeasurement] = []
        for i in 0..<140 {
            let x: Double
            if i < 30 { x = 0 } // User copied the demo too early and is at the wrong end.
            else if i < 60 { x = 0.4 }
            else if i < 90 { x = 0.4*Double(90-i)/30 }
            else { x = 0 }
            if let event = detector.process(time: Double(i)/30,pose: .init(x: x,y: 0)) {
                if event == .ready { XCTAssertGreaterThanOrEqual(i,30) }
                if case .completed(let measurement) = event { measurements.append(measurement) }
            }
        }
        XCTAssertEqual(measurements.count,1)
        let result = try XCTUnwrap(measurements.first)
        XCTAssertEqual(result.delta.x,-0.4,accuracy: 0.01)
        XCTAssertNotNil(result.start); XCTAssertNotNil(result.end)
    }
    func testInterruptedReverseStillRequiresTheCorrectStartingEnd() {
        var detector = SweepDetector(expectedStart: .init(x: 0.4,y: 0))
        for i in 0..<25 { _ = detector.process(time: Double(i)/30,pose: .init(x: 0.4,y: 0)) }
        XCTAssertEqual(detector.process(time: 2,pose: .zero),.interrupted)
        for i in 1..<35 {
            let event = detector.process(time: 2+Double(i)/30,pose: .zero)
            XCTAssertNotEqual(event,.ready)
        }
    }
    func obliqueSweeps(angle: Double) -> [SweepDirection: SweepMeasurement] {
        let radians = angle * .pi/180
        let v = PointerOffset(x: 0.3*cos(radians),y: 0.3*sin(radians))
        return [.topDown: .init(delta: v,duration: 1),
                .bottomUp: .init(delta: .init(x: -v.x,y: -v.y),duration: 1),
                .leftRight: .init(delta: .init(x: 0.3,y: 0),duration: 1),
                .rightLeft: .init(delta: .init(x: -0.3,y: 0),duration: 1)]
    }
    func testNaturalObliqueHorizontalMotionUsesTheSameConditionAsFinalMapping() throws {
        let sweeps = obliqueSweeps(angle: 30)
        try SweepCalibration.validate(sweeps[.leftRight]!,direction: .leftRight,previous: sweeps)
        let profile = try SweepCalibration.train(sweeps)
        let right = profile.map(.init(x: 0.15,y: 0))
        let vertical = sweeps[.topDown]!.delta
        let down = profile.map(.init(x: vertical.x/2,y: vertical.y/2))
        XCTAssertEqual(right.x,1,accuracy: 0.00001); XCTAssertEqual(right.y,0,accuracy: 0.00001)
        XCTAssertEqual(down.x,0,accuracy: 0.00001); XCTAssertEqual(down.y,1,accuracy: 0.00001)
    }
    func testNearlyParallelAxesRemainRejectedByStepAndFinalMapping() {
        let sweeps = obliqueSweeps(angle: 10)
        XCTAssertThrowsError(try SweepCalibration.validate(sweeps[.leftRight]!,direction: .leftRight,previous: sweeps))
        XCTAssertThrowsError(try SweepCalibration.train(sweeps))
    }
    func testHorizontalReferenceAveragesBothVerticalPasses() throws {
        var sweeps = obliqueSweeps(angle: 20)
        let angle = 40.0 * .pi/180
        sweeps[.bottomUp] = .init(delta: .init(x: -0.3*cos(angle),y: -0.3*sin(angle)),duration: 1)
        let horizontal = sweeps[.leftRight]!.delta
        XCTAssertEqual(try XCTUnwrap(SweepCalibration.separationDegrees(horizontal,previous: sweeps)),30,accuracy: 0.0001)
        try SweepCalibration.validate(sweeps[.leftRight]!,direction: .leftRight,previous: sweeps)
        XCTAssertTrue(try SweepCalibration.train(sweeps).isValid)
    }
}
