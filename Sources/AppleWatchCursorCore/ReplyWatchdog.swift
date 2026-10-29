import Foundation

/// Missing replies count only while the app is scheduled continuously.
/// A timer delivered after Always On throttling is not proof of a dead link.
public struct ReplyWatchdog: Sendable {
    public enum Health: Equatable, Sendable { case healthy, resuming, delayed, unresponsive }
    private var lastReply = 0.0
    private var lastTick: Double?
    private var graceUntil = 0.0
    public init() {}
    public mutating func resume(now: Double) {
        lastReply = now; lastTick = nil; graceUntil = now+3
    }
    public mutating func receivedReply(now: Double) {
        guard now.isFinite else { return }
        lastReply = now
    }
    public mutating func tick(now: Double, interactive: Bool) -> Health {
        guard now.isFinite else { return .resuming }
        let gap = lastTick.map { now-$0 > 1.5 } ?? true
        lastTick = now
        if !interactive || gap { graceUntil = now+3; return .resuming }
        guard now >= graceUntil else { return .resuming }
        let silence = now-lastReply
        if silence > 15 { return .unresponsive }
        if silence > 8 { return .delayed }
        return .healthy
    }
}
