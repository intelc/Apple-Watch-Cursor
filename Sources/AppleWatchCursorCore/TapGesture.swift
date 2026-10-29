import Foundation

/// Classifies on sensor timestamps, so delayed Bluetooth delivery cannot turn
/// two old single taps into a mode toggle. The toggle never also emits a click.
public struct TapGestureRecognizer: Sendable {
    public enum Action: Equatable, Sendable { case singleClick, toggleControl }
    public let doubleTapWindow: Double
    private var pending: Double?
    private var secondCandidateUntil: Double?
    private var cooldownUntil = -Double.infinity
    public var hasPendingTap: Bool { pending != nil }
    public init(doubleTapWindow: Double = 0.5) { self.doubleTapWindow = doubleTapWindow }
    public mutating func reset() { self = Self(doubleTapWindow: doubleTapWindow) }

    public mutating func cancelPending() { pending = nil; secondCandidateUntil = nil }

    public mutating func began(time: Double) {
        guard time.isFinite, time >= cooldownUntil, let pending,
              time >= pending, time-pending <= doubleTapWindow else { return }
        secondCandidateUntil = time+0.5
    }
    public mutating func recognized(time: Double) -> Action? {
        guard time.isFinite, time >= cooldownUntil else { return nil }
        if let pending {
            guard time >= pending else { return nil }
            if time-pending <= doubleTapWindow || secondCandidateUntil.map({ time <= $0 }) == true {
                self.pending = nil; secondCandidateUntil = nil; cooldownUntil = time+0.7
                return .toggleControl
            }
            self.pending = time; secondCandidateUntil = nil
            return .singleClick
        }
        pending = time; return nil
    }
    public mutating func rejected(time: Double) -> Action? {
        secondCandidateUntil = nil; return poll(time: time)
    }
    public mutating func poll(time: Double) -> Action? {
        guard time.isFinite, let pending, time-pending > doubleTapWindow else { return nil }
        if let until = secondCandidateUntil, time <= until { return nil }
        self.pending = nil; secondCandidateUntil = nil
        return .singleClick
    }
}

public enum MouseControlPolicy {
    public enum Block: String, Sendable {
        case connection = "Connect your Watch first"
        case calibration = "Calibrate pointing first"
        case calibrating = "Finish calibration first"
        case permission = "Allow Accessibility to control the mouse"
        case motion = "Wake the Watch and hold still to prepare pointing"
    }
    public static func block(paired: Bool, calibrated: Bool, calibrating: Bool,
                             permission: Bool, practice: Bool, motionAge: Double?) -> Block? {
        guard paired else { return .connection }
        guard calibrated else { return .calibration }
        guard !calibrating else { return .calibrating }
        guard practice || permission else { return .permission }
        guard let motionAge, motionAge.isFinite, (0..<0.3).contains(motionAge) else { return .motion }
        return nil
    }
}
