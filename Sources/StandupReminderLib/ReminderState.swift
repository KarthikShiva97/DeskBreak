import Foundation

// MARK: - Break Cycle State

/// Groups the per-break-cycle flags that track progress toward the next break.
///
/// All fields reset together when:
/// - A break fires
/// - The user is idle long enough (natural rest)
/// - The session resets or tracking resumes after disable
public struct BreakCycleState {
    public var snoozesUsed: Int = 0
    public var warningShown: Bool = false
    public var postureNudgeShown: Bool = false

    public static let maxSnoozes = 2
    public static let snoozeDurations: [TimeInterval] = [5 * 60, 2 * 60]

    public init() {}

    /// Reset all cycle tracking to initial state.
    public mutating func reset() {
        self = BreakCycleState()
    }

    public var canSnooze: Bool { snoozesUsed < Self.maxSnoozes }

    public var nextSnoozeDuration: TimeInterval {
        guard canSnooze else { return 0 }
        return Self.snoozeDurations[snoozesUsed]
    }

    public var nextSnoozeLabel: String {
        guard canSnooze else { return "" }
        return "\(Int(Self.snoozeDurations[snoozesUsed] / 60))m"
    }
}

// MARK: - Sitting Tracker

/// Tracks continuous sitting duration and health-warning state.
///
/// Reset when the user completes a break or goes idle outside a meeting
/// (likely stood up).  The sitting timer counts both active work and meeting
/// time since the user remains seated in both cases.
public struct SittingTracker {
    public var continuousSeconds: TimeInterval = 0
    public var firmWarningShown: Bool = false
    public var urgentWarningShown: Bool = false
    public var lastUrgentWarningAt: TimeInterval = 0

    public static let firmThreshold: TimeInterval = 60 * 60        // 60 minutes
    public static let urgentThreshold: TimeInterval = 90 * 60       // 90 minutes
    public static let urgentRepeatInterval: TimeInterval = 10 * 60  // repeat every 10 min

    public init() {}

    public var isUrgent: Bool { continuousSeconds >= Self.urgentThreshold }

    public var continuousMinutes: Int { Int(continuousSeconds) / 60 }

    /// Reset all sitting tracking to initial state.
    public mutating func reset() {
        self = SittingTracker()
    }
}
