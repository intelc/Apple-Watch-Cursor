import Foundation

public enum AxisCalibrationError: Error, LocalizedError {
    case tooSmall, notOpposite, similarAxes, offCenter
    public var errorDescription: String? {
        switch self {
        case .tooSmall: return "Use a larger, comfortable wrist rotation in each direction."
        case .notOpposite: return "Move back across the range in the reverse direction, then hold at the opposite end."
        case .similarAxes: return "For this horizontal step, make a clear side-to-side wrist sweep. Your completed vertical steps are kept."
        case .offCenter: return "The neutral pose shifted between movements. Return to the same comfortable center each time."
        }
    }
}

/// Inverse of the wearer's horizontal/vertical movement basis, in radians.
public struct AxisCalibrationProfile: Codable, Equatable, Sendable {
    public static let minimumAxisSine = 0.45
    public static func axesAreSeparable(_ a: PointerOffset, _ b: PointerOffset) -> Bool {
        let product = hypot(a.x,a.y)*hypot(b.x,b.y)
        guard product.isFinite, product > 0 else { return false }
        return abs(a.x*b.y-a.y*b.x)/product > minimumAxisSine
    }
    public let xx: Double
    public let xy: Double
    public let yx: Double
    public let yy: Double
    public var isValid: Bool {
        [xx, xy, yx, yy].allSatisfy { $0.isFinite && abs($0) < 50 } && abs(xx*yy-xy*yx) > 0.0001
    }
    public func map(_ angles: PointerOffset) -> PointerOffset {
        guard isValid, angles.x.isFinite, angles.y.isFinite else { return .zero }
        return .init(x: min(1, max(-1, xx*angles.x + xy*angles.y)),
                     y: min(1, max(-1, yx*angles.x + yy*angles.y)))
    }

    public static func train(neutral: PointerOffset, right: PointerOffset, left: PointerOffset,
                             up: PointerOffset, down: PointerOffset) throws -> Self {
        func relative(_ p: PointerOffset) -> PointerOffset {
            .init(x: PointerMapper.wrap(p.x-neutral.x), y: p.y-neutral.y)
        }
        func length(_ p: PointerOffset) -> Double { hypot(p.x, p.y) }
        func dot(_ a: PointerOffset, _ b: PointerOffset) -> Double { a.x*b.x + a.y*b.y }
        let r = relative(right), l = relative(left), u = relative(up), d = relative(down)
        guard [r,l,u,d].allSatisfy({ length($0).isFinite && (0.05...1.2).contains(length($0)) }) else {
            throw AxisCalibrationError.tooSmall
        }
        guard dot(r,l) / (length(r)*length(l)) < -0.5,
              dot(u,d) / (length(u)*length(d)) < -0.5 else { throw AxisCalibrationError.notOpposite }
        let h = PointerOffset(x: (r.x-l.x)/2, y: (r.y-l.y)/2)
        let v = PointerOffset(x: (d.x-u.x)/2, y: (d.y-u.y)/2)
        let det = h.x*v.y-h.y*v.x
        guard Self.axesAreSeparable(h,v) else { throw AxisCalibrationError.similarAxes }
        guard hypot(r.x+l.x,r.y+l.y)/2 < length(h)*0.35,
              hypot(d.x+u.x,d.y+u.y)/2 < length(v)*0.35 else { throw AxisCalibrationError.offCenter }
        let result = Self(xx: v.y/det, xy: -v.x/det, yx: -h.y/det, yy: h.x/det)
        guard result.isValid else { throw AxisCalibrationError.tooSmall }
        return result
    }
}

/// Requires fresh, steady samples; interrupted or stale windows cannot be captured.
public struct StablePoseWindow: Sendable {
    public enum Readiness: String, Sendable {
        case noData = "Waiting for Watch sensor data"
        case stale = "Watch data paused · wake its display"
        case collecting = "Receiving data · hold this pose for a moment"
        case moving = "Receiving data · hold your wrist more still"
        case ready = "Steady · ready to capture"
    }
    private var samples: [(time: Double, pose: PointerOffset)] = []
    public init() {}
    public mutating func reset() { samples = [] }
    public func readiness(now: Double) -> Readiness {
        guard let first = samples.first, let last = samples.last else { return .noData }
        guard now.isFinite, now >= last.time, now-last.time < 0.2 else { return .stale }
        guard samples.count >= 12, last.time-first.time >= 0.4 else { return .collecting }
        return mean(now: now) == nil ? .moving : .ready
    }
    public mutating func append(time: Double, pose: PointerOffset) {
        guard time.isFinite, pose.x.isFinite, pose.y.isFinite else { return }
        if let last = samples.last {
            guard time > last.time else { return }
            if time-last.time > 0.15 { reset() }
        }
        samples.append((time,pose)); samples.removeAll { time-$0.time > 0.65 }
    }
    public func mean(now: Double) -> PointerOffset? {
        guard now.isFinite, let first = samples.first, let last = samples.last,
              samples.count >= 12, last.time-first.time >= 0.4,
              now >= last.time, now-last.time < 0.2 else { return nil }
        let n = Double(samples.count)
        let yaw = atan2(samples.reduce(0) { $0+sin($1.pose.x) }, samples.reduce(0) { $0+cos($1.pose.x) })
        let y = samples.reduce(0) { $0+$1.pose.y }/n
        let variance = samples.reduce(0) { sum, sample in
            sum + pow(PointerMapper.wrap(sample.pose.x-yaw),2) + pow(sample.pose.y-y,2)
        }/n
        guard variance < pow(0.012,2) else { return nil }
        return .init(x: yaw, y: y)
    }
}
