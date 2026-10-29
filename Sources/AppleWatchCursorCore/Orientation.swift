import Foundation

public struct Quaternion: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double
    public var w: Double
    public init(_ x: Double,_ y: Double,_ z: Double,_ w: Double) { self.x=x; self.y=y; self.z=z; self.w=w }
    public static let identity = Self(0,0,0,1)
    public var unit: Self? {
        let n = sqrt(x*x+y*y+z*z+w*w)
        guard n.isFinite, n > 1e-9 else { return nil }
        return .init(x/n,y/n,z/n,w/n)
    }
    public var conjugate: Self { .init(-x,-y,-z,w) }
    public static func * (a: Self,b: Self) -> Self {
        .init(a.w*b.x+a.x*b.w+a.y*b.z-a.z*b.y,
              a.w*b.y-a.x*b.z+a.y*b.w+a.z*b.x,
              a.w*b.z+a.x*b.y-a.y*b.x+a.z*b.w,
              a.w*b.w-a.x*b.x-a.y*b.y-a.z*b.z)
    }
    public static func fromRotationVector(_ v: Vector3) -> Self {
        let angle=v.magnitude
        guard angle > 1e-9 else { return .identity }
        let s=sin(angle/2)/angle
        return .init(v.x*s,v.y*s,v.z*s,cos(angle/2))
    }
    /// Matches Core Motion's current attitude multiplied by inverse reference.
    public func rotation(to target: Self) -> Vector3? {
        guard let reference=unit, let current=target.unit, var q=(current*reference.conjugate).unit else { return nil }
        if q.w < 0 { q = .init(-q.x,-q.y,-q.z,-q.w) }
        let s=hypot(hypot(q.x,q.y),q.z)
        guard s > 1e-9 else { return .init(0,0,0) }
        let scale=2*atan2(s,max(0,q.w))/s
        return .init(q.x*scale,q.y*scale,q.z*scale)
    }
    public func distance(to other: Self) -> Double? { rotation(to: other)?.magnitude }
    public static func mean(_ values: [Self]) -> Self? {
        guard let first=values.first?.unit else { return nil }
        var total=Self(0,0,0,0)
        for value in values {
            guard let q=value.unit else { return nil }
            let sign=first.x*q.x+first.y*q.y+first.z*q.z+first.w*q.w < 0 ? -1.0 : 1.0
            total.x += q.x*sign; total.y += q.y*sign; total.z += q.z*sign; total.w += q.w*sign
        }
        return total.unit
    }
}

public extension Vector3 {
    func dot(_ b: Self) -> Double { x*b.x+y*b.y+z*b.z }
    func cross(_ b: Self) -> Self { .init(y*b.z-z*b.y,z*b.x-x*b.z,x*b.y-y*b.x) }
}

public struct PointerPose: Equatable, Sendable {
    public let offset: PointerOffset
    public let orientation: Quaternion?
    public init(offset: PointerOffset,orientation: Quaternion?) { self.offset=offset; self.orientation=orientation }
}

public struct OrientationWindow: Sendable {
    private var samples: [(time: Double,pose: Quaternion)] = []
    public init() {}
    public mutating func reset() { samples=[] }
    public mutating func append(time: Double,pose: Quaternion) {
        guard time.isFinite, let unit=pose.unit else { return }
        if let last=samples.last {
            guard time > last.time else { return }
            if time-last.time > 0.15 { reset() }
        }
        samples.append((time,unit)); samples.removeAll { time-$0.time > 0.65 }
    }
    public func mean(now: Double) -> Quaternion? {
        guard now.isFinite, let first=samples.first, let last=samples.last,
              samples.count >= 12, last.time-first.time >= 0.4, now >= last.time, now-last.time < 0.2,
              let mean=Quaternion.mean(samples.map(\.pose)) else { return nil }
        let variance=samples.reduce(0.0) { $0+pow(mean.distance(to: $1.pose) ?? .infinity,2) }/Double(samples.count)
        return variance < 0.012*0.012 ? mean : nil
    }
}

public struct OrientationSweep: Equatable, Sendable {
    public let start: Quaternion
    public let end: Quaternion
    public let duration: Double
    public init(start: Quaternion,end: Quaternion,duration: Double) { self.start=start; self.end=end; self.duration=duration }
}

public struct OrientationSweepDetector: Sendable {
    public enum Stage: Sendable { case settling, ready, moving, complete }
    public enum Event: Equatable, Sendable { case ready, moving, completed(OrientationSweep), interrupted, retry }
    public private(set) var stage: Stage = .settling
    private var window=OrientationWindow()
    private var start: Quaternion?
    private var last: (time: Double,pose: Quaternion)?
    private var movingAt: Double?
    private var travel=0.0
    private let expectedStart: Quaternion?
    private let tolerance: Double
    public init(expectedStart: Quaternion? = nil,tolerance: Double = 0.08) { self.expectedStart=expectedStart; self.tolerance=tolerance }
    public mutating func reset() { self=Self(expectedStart: expectedStart,tolerance: tolerance) }
    public mutating func process(time: Double,pose: Quaternion) -> Event? {
        guard time.isFinite, let pose=pose.unit, stage != .complete else { return nil }
        if let last {
            guard time > last.time else { return nil }
            if time-last.time > 0.2 {
                reset(); self.last=(time,pose); window.append(time: time,pose: pose); return .interrupted
            }
        }
        let previous=last; last=(time,pose); window.append(time: time,pose: pose)
        guard let start else {
            if let steady=window.mean(now: time) {
                if let expectedStart, (expectedStart.distance(to: steady) ?? .infinity) > tolerance { return nil }
                self.start=steady; stage = .ready; return .ready
            }
            return nil
        }
        let distance=start.distance(to: pose) ?? 0
        if stage == .ready, distance > 0.03 { stage = .moving; movingAt=time; travel=distance; return .moving }
        guard stage == .moving, let movingAt else { return nil }
        if let previous { travel += previous.pose.distance(to: pose) ?? 0 }
        if time-movingAt > 6 { reset(); return .retry }
        guard let end=window.mean(now: time), time-movingAt >= 0.3 else { return nil }
        let length=start.distance(to: end) ?? 0
        guard (0.12...2.4).contains(length), length/max(travel,0.0001) >= 0.65 else { reset(); return .retry }
        stage = .complete
        return .completed(.init(start: start,end: end,duration: time-movingAt))
    }
}

public struct OrientationCalibrationProfile: Codable, Equatable, Sendable {
    public let horizontal: Vector3
    public let vertical: Vector3
    public var isValid: Bool {
        horizontal.isFinite && vertical.isFinite && horizontal.magnitude < 50 && vertical.magnitude < 50 &&
        horizontal.cross(vertical).magnitude > 0.0001
    }
    public func map(_ rotation: Vector3) -> PointerOffset {
        guard isValid, rotation.isFinite else { return .zero }
        return .init(x: min(1,max(-1,horizontal.dot(rotation))),y: min(1,max(-1,vertical.dot(rotation))))
    }
    private static func reference(_ sweeps: [SweepDirection: OrientationSweep]) -> Quaternion? {
        guard let down=sweeps[.topDown] else { return nil }
        var poses=[down.start,down.end]
        if let up=sweeps[.bottomUp] { poses += [up.start,up.end] }
        return Quaternion.mean(poses)
    }
    public static func delta(_ sweep: OrientationSweep,reference: Quaternion) -> Vector3? {
        guard let a=reference.rotation(to: sweep.start), let b=reference.rotation(to: sweep.end) else { return nil }
        return b-a
    }
    public static func separationDegrees(_ sweep: OrientationSweep,previous: [SweepDirection: OrientationSweep]) -> Double? {
        guard let ref=reference(previous), let down=previous[.topDown], let v1=delta(down,reference: ref),
              let h=delta(sweep,reference: ref) else { return nil }
        let v: Vector3
        if let up=previous[.bottomUp], let v2=delta(up,reference: ref) { v=(v1-v2)*0.5 } else { v=v1 }
        let product=h.magnitude*v.magnitude
        guard product > 0 else { return nil }
        return acos(min(1,max(0,abs(h.dot(v))/product)))*180 / .pi
    }
    public static func validate(_ sweep: OrientationSweep,direction: SweepDirection,previous: [SweepDirection: OrientationSweep]) throws {
        let angle=sweep.start.distance(to: sweep.end) ?? 0
        guard (0.12...2.4).contains(angle), sweep.duration.isFinite, (0.3...6).contains(sweep.duration) else { throw AxisCalibrationError.tooSmall }
        var all=previous; all[direction]=sweep
        guard let ref=reference(all), let a=delta(sweep,reference: ref) else { throw AxisCalibrationError.tooSmall }
        let opposite: SweepDirection? = direction == .bottomUp ? .topDown : direction == .rightLeft ? .leftRight : nil
        if let opposite {
            guard let other=previous[opposite], let b=delta(other,reference: ref),
                  a.dot(b)/(a.magnitude*b.magnitude) < -0.8,
                  (0.4...2.5).contains(a.magnitude/b.magnitude) else { throw AxisCalibrationError.notOpposite }
        }
        if direction == .leftRight {
            guard let separation=separationDegrees(sweep,previous: previous), sin(separation * .pi/180) > AxisCalibrationProfile.minimumAxisSine else {
                throw AxisCalibrationError.similarAxes
            }
        }
    }
    public static func train(_ sweeps: [SweepDirection: OrientationSweep]) throws -> Self {
        for direction in SweepDirection.allCases {
            guard let sweep=sweeps[direction] else { throw AxisCalibrationError.tooSmall }
            try validate(sweep,direction: direction,previous: sweeps)
        }
        guard let ref=reference(sweeps), let td=delta(sweeps[.topDown]!,reference: ref),
              let bu=delta(sweeps[.bottomUp]!,reference: ref), let lr=delta(sweeps[.leftRight]!,reference: ref),
              let rl=delta(sweeps[.rightLeft]!,reference: ref) else { throw AxisCalibrationError.tooSmall }
        let h=(lr-rl)*0.25, v=(td-bu)*0.25
        let hh=h.dot(h), vv=v.dot(v), hv=h.dot(v), det=hh*vv-hv*hv
        guard h.cross(v).magnitude/(h.magnitude*v.magnitude) > AxisCalibrationProfile.minimumAxisSine else { throw AxisCalibrationError.similarAxes }
        guard det.isFinite, det > 1e-9 else { throw AxisCalibrationError.similarAxes }
        let result=Self(horizontal:(h*vv-v*hv)*(1/det),vertical:(v*hh-h*hv)*(1/det))
        guard result.isValid else { throw AxisCalibrationError.tooSmall }
        return result
    }
}
