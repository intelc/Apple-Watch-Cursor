import Foundation

public enum SweepDirection: Int, CaseIterable, Hashable, Sendable {
    case topDown, bottomUp, leftRight, rightLeft
    public var title: String {
        switch self {
        case .topDown: return "Top → bottom"
        case .bottomUp: return "Bottom → top"
        case .leftRight: return "Left → right"
        case .rightLeft: return "Right → left"
        }
    }
    public var startName: String {
        switch self {
        case .topDown: return "top"
        case .bottomUp: return "bottom"
        case .leftRight: return "left"
        case .rightLeft: return "right"
        }
    }
    public var isVertical: Bool { self == .topDown || self == .bottomUp }
}

public struct SweepMeasurement: Equatable, Sendable {
    public let delta: PointerOffset
    public let duration: Double
    public let start: PointerOffset?
    public let end: PointerOffset?
    public init(delta: PointerOffset, duration: Double, start: PointerOffset? = nil, end: PointerOffset? = nil) {
        self.delta = delta; self.duration = duration; self.start = start; self.end = end
    }
}

/// A steady start, deliberate traversal, and steady finish produce one sweep.
/// Gaps reset the gesture instead of joining old and new positions.
public struct SweepDetector: Sendable {
    public enum Stage: Sendable { case settling, ready, moving, complete }
    public enum Event: Equatable, Sendable {
        case ready, moving, completed(SweepMeasurement), interrupted, retry
    }
    public private(set) var stage: Stage = .settling
    private var window = StablePoseWindow()
    private var start: PointerOffset?
    private var last: (time: Double, pose: PointerOffset)?
    private var movingAt: Double?
    private var travel = 0.0
    private var expectedStart: PointerOffset?
    private var startTolerance: Double
    public init(expectedStart: PointerOffset? = nil, startTolerance: Double = 0.08) {
        self.expectedStart = expectedStart; self.startTolerance = startTolerance
    }
    public mutating func reset() { self = Self(expectedStart: expectedStart,startTolerance: startTolerance) }
    public mutating func process(time: Double, pose: PointerOffset) -> Event? {
        guard time.isFinite, pose.x.isFinite, pose.y.isFinite, stage != .complete else { return nil }
        if let last {
            guard time > last.time else { return nil }
            if time-last.time > 0.2 {
                reset(); self.last = (time,pose); window.append(time: time,pose: pose)
                return .interrupted
            }
        }
        let previous = last; last = (time,pose)
        window.append(time: time,pose: pose)
        guard let start else {
            if let steady = window.mean(now: time) {
                if let expectedStart,
                   hypot(PointerMapper.wrap(steady.x-expectedStart.x),steady.y-expectedStart.y) > startTolerance { return nil }
                self.start = steady; stage = .ready; return .ready
            }
            return nil
        }
        let delta = PointerOffset(x: PointerMapper.wrap(pose.x-start.x),y: pose.y-start.y)
        let distance = hypot(delta.x,delta.y)
        if stage == .ready, distance > 0.03 {
            stage = .moving; movingAt = time; travel = distance
            return .moving
        }
        guard stage == .moving, let movingAt else { return nil }
        if let previous { travel += hypot(PointerMapper.wrap(pose.x-previous.pose.x),pose.y-previous.pose.y) }
        if time-movingAt > 6 { reset(); return .retry }
        guard let end = window.mean(now: time), time-movingAt >= 0.3 else { return nil }
        let sweep = PointerOffset(x: PointerMapper.wrap(end.x-start.x),y: end.y-start.y)
        let length = hypot(sweep.x,sweep.y)
        guard length >= 0.12 else {
            // A small excursion or a return to the starting point isn't a sweep.
            self.start = end; stage = .ready; self.movingAt = nil; travel = 0
            return .retry
        }
        guard length <= 2.4, length/max(travel,0.0001) >= 0.7 else { reset(); return .retry }
        stage = .complete
        return .completed(.init(delta: sweep,duration: time-movingAt,start: start,end: end))
    }
}

public enum SweepCalibration {
    public static func verticalReference(_ sweeps: [SweepDirection: SweepMeasurement]) -> PointerOffset? {
        guard let down = sweeps[.topDown]?.delta else { return nil }
        guard let up = sweeps[.bottomUp]?.delta else { return down }
        return .init(x: (down.x-up.x)/2,y: (down.y-up.y)/2)
    }
    public static func separationDegrees(_ horizontal: PointerOffset, previous: [SweepDirection: SweepMeasurement]) -> Double? {
        guard let vertical = verticalReference(previous) else { return nil }
        let product = hypot(horizontal.x,horizontal.y)*hypot(vertical.x,vertical.y)
        guard product.isFinite, product > 0 else { return nil }
        let cosine = abs(horizontal.x*vertical.x+horizontal.y*vertical.y)/product
        return acos(min(1,max(0,cosine)))*180 / .pi
    }
    public static func validate(_ measurement: SweepMeasurement, direction: SweepDirection,
                                previous: [SweepDirection: SweepMeasurement]) throws {
        let a = measurement.delta, length = hypot(a.x,a.y)
        guard length.isFinite, (0.12...2.4).contains(length),
              measurement.duration.isFinite, (0.3...6).contains(measurement.duration) else { throw AxisCalibrationError.tooSmall }
        func cosine(_ b: PointerOffset) -> Double { (a.x*b.x+a.y*b.y)/(length*hypot(b.x,b.y)) }
        let opposite: SweepDirection? = direction == .bottomUp ? .topDown : direction == .rightLeft ? .leftRight : nil
        if let opposite {
            guard let b = previous[opposite]?.delta, cosine(b) < -0.8,
                  (0.4...2.5).contains(length/hypot(b.x,b.y)) else { throw AxisCalibrationError.notOpposite }
        }
        if direction == .leftRight {
            guard let v = verticalReference(previous), AxisCalibrationProfile.axesAreSeparable(a,v) else {
                throw AxisCalibrationError.similarAxes
            }
        }
    }

    public static func train(_ sweeps: [SweepDirection: SweepMeasurement]) throws -> AxisCalibrationProfile {
        for direction in SweepDirection.allCases {
            guard let measurement = sweeps[direction] else { throw AxisCalibrationError.tooSmall }
            try validate(measurement,direction: direction,previous: sweeps)
        }
        let td = sweeps[.topDown]!.delta, bu = sweeps[.bottomUp]!.delta
        let lr = sweeps[.leftRight]!.delta, rl = sweeps[.rightLeft]!.delta
        let h = PointerOffset(x: (lr.x-rl.x)/4,y: (lr.y-rl.y)/4)
        let v = PointerOffset(x: (td.x-bu.x)/4,y: (td.y-bu.y)/4)
        return try .train(neutral: .zero,right: h,left: .init(x: -h.x,y: -h.y),
                          up: .init(x: -v.x,y: -v.y),down: v)
    }
}
