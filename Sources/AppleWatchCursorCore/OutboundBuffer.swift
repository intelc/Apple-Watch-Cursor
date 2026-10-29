import Foundation

public struct OutboundIntent: Equatable, Sendable {
    public let kind: CommandFrame.Kind
    public let x: Double
    public let y: Double
    public let orientation: Quaternion?
    public init(kind: CommandFrame.Kind, x: Double = 0, y: Double = 0, orientation: Quaternion? = nil) {
        self.kind = kind; self.x = x; self.y = y; self.orientation = orientation
    }
}

/// Coalesces movement without letting an unrelated heartbeat acknowledgement
/// hold the pointer still. Input actions retain their reliable ordering.
public struct OutboundBuffer: Sendable {
    public private(set) var pendingReliable: CommandFrame.Kind?
    private var reliable: [OutboundIntent] = []
    private var latestMove: OutboundIntent?
    public init() {}
    public mutating func reset() { self = Self() }
    public mutating func clearQueuedKeepingFlight() { reliable = []; latestMove = nil }
    public mutating func beginHello() -> Bool {
        guard pendingReliable == nil else { return false }
        pendingReliable = .hello; return true
    }
    public mutating func acknowledge() { pendingReliable = nil }
    public mutating func enqueue(_ intent: OutboundIntent) -> Bool {
        if intent.kind.isMovement { latestMove = intent; return true }
        if intent.kind == .pause { reliable = []; latestMove = nil }
        if intent.kind == .heartbeat, pendingReliable != nil || !reliable.isEmpty { return true }
        guard reliable.count < 8 else { return false }
        reliable.append(intent); return true
    }
    public mutating func next(canSendMovement: Bool) -> OutboundIntent? {
        if let pendingReliable {
            guard pendingReliable == .heartbeat, canSendMovement, let move = latestMove else { return nil }
            latestMove = nil; return move
        }
        if !reliable.isEmpty {
            let next = reliable.removeFirst(); pendingReliable = next.kind; return next
        }
        guard canSendMovement, let move = latestMove else { return nil }
        latestMove = nil; return move
    }
}
