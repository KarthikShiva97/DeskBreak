import Foundation

// MARK: - Break Cycle State

/// Groups the per-break-cycle flags that track progress toward the next break.
///
/// All fields reset together when:
/// - A break fires
/// - The user is idle long enough (natural rest)
/// - The session resets or tracking resumes after disable
struct BreakCycleState {
    var snoozesUsed: Int = 0
    var warningShown: Bool = false
    var postureNudgeShown: Bool = false

    static let maxSnoozes = 2
    static let snoozeDurations: [TimeInterval] = [5 * 60, 2 * 60]

    /// Reset all cycle tracking to initial state.
    mutating func reset() {
        self = BreakCycleState()
    }

    var canSnooze: Bool { snoozesUsed < Self.maxSnoozes }

    var nextSnoozeDuration: TimeInterval {
        guard canSnooze else { return 0 }
        return Self.snoozeDurations[snoozesUsed]
    }

    var nextSnoozeLabel: String {
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
struct SittingTracker {
    var continuousSeconds: TimeInterval = 0
    var firmWarningShown: Bool = false
    var urgentWarningShown: Bool = false
    var lastUrgentWarningAt: TimeInterval = 0

    static let firmThreshold: TimeInterval = 60 * 60        // 60 minutes
    static let urgentThreshold: TimeInterval = 90 * 60       // 90 minutes
    static let urgentRepeatInterval: TimeInterval = 10 * 60  // repeat every 10 min

    var isUrgent: Bool { continuousSeconds >= Self.urgentThreshold }

    var continuousMinutes: Int { Int(continuousSeconds) / 60 }

    /// Reset all sitting tracking to initial state.
    mutating func reset() {
        self = SittingTracker()
    }
}
