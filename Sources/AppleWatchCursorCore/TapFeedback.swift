import Foundation

/// Records received detections independently of permission to click the computer.
/// Call only after the command's trusted session and sequence have been accepted.
public struct TapFeedback: Sendable {
    public enum Outcome: String, Sendable {
        case practice, paused, staleMotion, rateLimited, permissionRequired, liveClick
    }
    public private(set) var receivedCount = 0
    private var lastLiveClick = -Double.infinity
    public init() {}

    public mutating func receive(now: Double, enabled: Bool, practiceOnly: Bool,
                                 hasPermission: Bool, lastMotion: Double?) -> Outcome {
        receivedCount += 1
        if practiceOnly { return .practice }
        guard enabled else { return .paused }
        guard hasPermission else { return .permissionRequired }
        guard now.isFinite, let lastMotion, lastMotion.isFinite,
              now >= lastMotion, now-lastMotion < 0.3 else { return .staleMotion }
        guard now-lastLiveClick > 0.25 else { return .rateLimited }
        lastLiveClick = now
        return .liveClick
    }
}
