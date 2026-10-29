import Foundation

public struct Vector3: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double
    public init(_ x: Double, _ y: Double, _ z: Double) { self.x = x; self.y = y; self.z = z }
    public var magnitude: Double { sqrt(x*x + y*y + z*z) }
    public static func -(lhs: Self, rhs: Self) -> Self { .init(lhs.x-rhs.x, lhs.y-rhs.y, lhs.z-rhs.z) }
    public static func +(lhs: Self, rhs: Self) -> Self { .init(lhs.x+rhs.x, lhs.y+rhs.y, lhs.z+rhs.z) }
    public static func *(lhs: Self, rhs: Double) -> Self { .init(lhs.x*rhs, lhs.y*rhs, lhs.z*rhs) }
    public var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
}

public struct MotionSample: Codable, Sendable {
    public var time: Double
    public var acceleration: Vector3 // Raw acceleration, in g, including gravity.
    public var rotation: Vector3 // Radians per second.
    public var yaw: Double
    public var pitch: Double
    public var orientation: Quaternion?
    public init(time: Double, acceleration: Vector3, rotation: Vector3, yaw: Double, pitch: Double, orientation: Quaternion? = nil) {
        self.time = time; self.acceleration = acceleration; self.rotation = rotation
        self.yaw = yaw; self.pitch = pitch; self.orientation = orientation
    }
    public var isFinite: Bool {
        time.isFinite && acceleration.isFinite && rotation.isFinite && yaw.isFinite && pitch.isFinite && (orientation == nil || orientation?.unit != nil)
    }
}

public struct PointerOffset: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public static let zero = Self(x: 0, y: 0)
    public func adjusted(verticalGain: Double, flipX: Bool, flipY: Bool) -> Self {
        let gain = verticalGain.isFinite ? min(4, max(0.5, verticalGain)) : 2
        return .init(x: min(1, max(-1, x * (flipX ? -1 : 1))),
                     y: min(1, max(-1, y * gain * (flipY ? -1 : 1))))
    }
}

/// Maps angular displacement to a screen offset. No acceleration integration or position tracking.
public struct PointerMapper: Sendable {
    public var horizontalRange = 0.40 // ~23 degrees from center to either edge
    public var verticalRange = 0.32
    public var smoothing = 0.055
    private var neutral: (yaw: Double, pitch: Double)?
    private var filtered = PointerOffset.zero
    private var previousTime: Double?
    public init() {}
    public mutating func reset() { neutral = nil; filtered = .zero; previousTime = nil }
    public mutating func recenter(yaw: Double, pitch: Double, time: Double) {
        guard yaw.isFinite, pitch.isFinite, time.isFinite else { return }
        neutral = (yaw, pitch); filtered = .zero; previousTime = time
    }
    public mutating func update(yaw: Double, pitch: Double, time: Double) -> PointerOffset? {
        guard yaw.isFinite, pitch.isFinite, time.isFinite else { return nil }
        guard let neutral, let last = previousTime else {
            recenter(yaw: yaw, pitch: pitch, time: time); return .zero
        }
        let dt = time - last
        guard dt > 0 else { return nil }
        // Drop delayed samples and require a new neutral after a sensor interruption.
        guard dt < 0.20 else { reset(); return nil }
        previousTime = time
        let x = Self.wrap(yaw - neutral.yaw) / max(horizontalRange, 0.1)
        let y = -(pitch - neutral.pitch) / max(verticalRange, 0.1)
        let a = 1 - exp(-dt / max(smoothing, 0.001))
        filtered.x += (Self.clamp(x) - filtered.x) * a
        filtered.y += (Self.clamp(y) - filtered.y) * a
        return filtered
    }
    private static func clamp(_ x: Double) -> Double { min(1, max(-1, x)) }
    public static func wrap(_ x: Double) -> Double { atan2(sin(x), cos(x)) }
}
