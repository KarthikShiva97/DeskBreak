import Foundation

/// Tracks stretch break statistics for the current session and persists daily streaks.
final class SessionStats {
    private let defaults = UserDefaults.standard

    /// Breaks completed in this session.
    private(set) var breaksCompleted: Int = 0

    /// Breaks skipped (user hit skip early) in this session.
    private(set) var breaksSkipped: Int = 0

    /// Breaks snoozed in this session.
    private(set) var breaksSnoozed: Int = 0

    /// Consecutive days with at least one completed break.
    var dailyStreak: Int {
        defaults.integer(forKey: "dailyStreak")
    }

    /// Total breaks completed all-time.
    var totalBreaksAllTime: Int {
        defaults.integer(forKey: "totalBreaksAllTime")
    }

    init() {
        updateDailyStreak()
    }

    func recordBreakCompleted() {
        breaksCompleted += 1
        defaults.set(totalBreaksAllTime + 1, forKey: "totalBreaksAllTime")
        markTodayActive()
    }

    func recordBreakSkipped() {
        breaksSkipped += 1
    }

    func recordBreakSnoozed() {
        breaksSnoozed += 1
    }

    /// Summary string shown in the menu bar and on quit.
    func sessionSummary(totalWorkSeconds: TimeInterval) -> String {
        let hours = Int(totalWorkSeconds) / 3600
        let mins = (Int(totalWorkSeconds) % 3600) / 60

        var lines: [String] = []

        if hours > 0 {
            lines.append("Session: \(hours)h \(mins)m worked")
        } else {
            lines.append("Session: \(mins)m worked")
        }

        lines.append("Breaks completed: \(breaksCompleted)")

        if breaksSkipped > 0 {
            lines.append("Breaks skipped early: \(breaksSkipped)")
        }
        if breaksSnoozed > 0 {
            lines.append("Breaks snoozed: \(breaksSnoozed)")
        }

        lines.append("Daily streak: \(dailyStreak) day\(dailyStreak == 1 ? "" : "s")")

        return lines.joined(separator: "\n")
    }

    // MARK: - Daily streak persistence

    private func markTodayActive() {
        let today = Self.todayString()
        defaults.set(today, forKey: "lastActiveDate")
        updateDailyStreak()
    }

    private func updateDailyStreak() {
        let today = Self.todayString()
        let lastActive = defaults.string(forKey: "lastActiveDate") ?? ""
        let yesterday = Self.yesterdayString()

        if lastActive == today {
            // Already active today, streak is current
            return
        } else if lastActive == yesterday {
            // Continuing streak from yesterday
            let current = defaults.integer(forKey: "dailyStreak")
            defaults.set(current + 1, forKey: "dailyStreak")
            defaults.set(today, forKey: "lastActiveDate")
        } else if lastActive.isEmpty {
            // First time
            defaults.set(1, forKey: "dailyStreak")
        } else {
            // Streak broken
            defaults.set(1, forKey: "dailyStreak")
        }
    }

    private static func todayString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private static func yesterdayString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        return formatter.string(from: yesterday)
    }
}
