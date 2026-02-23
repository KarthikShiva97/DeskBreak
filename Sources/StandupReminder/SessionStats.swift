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

    /// Health warnings received this session.
    private(set) var healthWarningsReceived: Int = 0

    /// Longest continuous sitting streak (seconds) this session.
    private(set) var longestContinuousSittingSeconds: TimeInterval = 0

    /// Consecutive days with at least one completed break.
    var dailyStreak: Int {
        defaults.integer(forKey: "dailyStreak")
    }

    /// Total breaks completed all-time.
    var totalBreaksAllTime: Int {
        defaults.integer(forKey: "totalBreaksAllTime")
    }

    init() {
        // Only check if the streak was broken (don't increment — that happens on break completion)
        let today = Self.todayString()
        let lastActive = defaults.string(forKey: "lastActiveDate") ?? ""
        let yesterday = Self.yesterdayString()
        if !lastActive.isEmpty && lastActive != today && lastActive != yesterday {
            // Streak broken — reset so the menu shows 0 until they complete a break
            defaults.set(0, forKey: "dailyStreak")
        }
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

    func recordHealthWarning() {
        healthWarningsReceived += 1
    }

    func updateLongestContinuousSitting(_ seconds: TimeInterval) {
        if seconds > longestContinuousSittingSeconds {
            longestContinuousSittingSeconds = seconds
        }
    }

    func resetSession() {
        breaksCompleted = 0
        breaksSkipped = 0
        breaksSnoozed = 0
        healthWarningsReceived = 0
        longestContinuousSittingSeconds = 0
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

        if longestContinuousSittingSeconds >= 3600 {
            let hrs = Int(longestContinuousSittingSeconds) / 3600
            let mins = (Int(longestContinuousSittingSeconds) % 3600) / 60
            lines.append("Longest sitting streak: \(hrs)h \(mins)m")
        }

        if healthWarningsReceived > 0 {
            lines.append("Health warnings: \(healthWarningsReceived)")
        }

        lines.append("Daily streak: \(dailyStreak) day\(dailyStreak == 1 ? "" : "s")")

        return lines.joined(separator: "\n")
    }

    // MARK: - Daily streak persistence

    private func markTodayActive() {
        updateDailyStreak()
        defaults.set(Self.todayString(), forKey: "lastActiveDate")
    }

    private func updateDailyStreak() {
        let today = Self.todayString()
        let lastActive = defaults.string(forKey: "lastActiveDate") ?? ""
        let yesterday = Self.yesterdayString()

        if lastActive == today {
            // Already counted today — don't double-increment
            return
        } else if lastActive == yesterday {
            defaults.set(dailyStreak + 1, forKey: "dailyStreak")
        } else {
            // First time or streak broken — start at 1
            defaults.set(1, forKey: "dailyStreak")
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func todayString() -> String {
        dateFormatter.string(from: Date())
    }

    private static func yesterdayString() -> String {
        guard let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) else {
            return ""
        }
        return dateFormatter.string(from: yesterday)
    }
}
