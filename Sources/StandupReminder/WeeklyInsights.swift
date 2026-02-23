import Foundation

/// Aggregates timeline data across multiple days to produce weekly insights
/// and detect streak milestones for celebration notifications.
final class WeeklyInsights {

    struct WeeklySummary {
        let breaksCompleted: Int
        let breaksSkipped: Int
        let breaksSnoozed: Int
        let healthWarnings: Int
        let totalWorkSeconds: TimeInterval
        let totalBreakSeconds: TimeInterval
        let daysActive: Int

        // Previous week for comparison (nil if no data)
        let prevBreaksCompleted: Int?
        let prevTotalWorkSeconds: TimeInterval?
        let prevHealthWarnings: Int?
        let prevDaysActive: Int?
    }

    // MARK: - Weekly Summary

    /// Generate a summary comparing the past 7 days to the 7 days before that.
    static func generateSummary() -> WeeklySummary {
        let thisWeek = aggregateMetrics(daysAgo: 0..<7)
        let prevWeek = aggregateMetrics(daysAgo: 7..<14)
        let hasPrevData = prevWeek.daysActive > 0

        return WeeklySummary(
            breaksCompleted: thisWeek.breaksCompleted,
            breaksSkipped: thisWeek.breaksSkipped,
            breaksSnoozed: thisWeek.breaksSnoozed,
            healthWarnings: thisWeek.healthWarnings,
            totalWorkSeconds: thisWeek.totalWorkSeconds,
            totalBreakSeconds: thisWeek.totalBreakSeconds,
            daysActive: thisWeek.daysActive,
            prevBreaksCompleted: hasPrevData ? prevWeek.breaksCompleted : nil,
            prevTotalWorkSeconds: hasPrevData ? prevWeek.totalWorkSeconds : nil,
            prevHealthWarnings: hasPrevData ? prevWeek.healthWarnings : nil,
            prevDaysActive: hasPrevData ? prevWeek.daysActive : nil
        )
    }

    // MARK: - Notification Formatting

    /// Format the weekly summary as a notification body string.
    static func formatNotificationBody(_ summary: WeeklySummary) -> String {
        var lines: [String] = []

        // Work time
        let workHours = Int(summary.totalWorkSeconds) / 3600
        let workMins = (Int(summary.totalWorkSeconds) % 3600) / 60
        if workHours > 0 {
            lines.append("Tracked \(workHours)h \(workMins)m across \(summary.daysActive) day\(summary.daysActive == 1 ? "" : "s")")
        } else {
            lines.append("Tracked \(workMins)m across \(summary.daysActive) day\(summary.daysActive == 1 ? "" : "s")")
        }

        // Break compliance
        let totalBreaks = summary.breaksCompleted + summary.breaksSkipped
        if totalBreaks > 0 {
            let complianceRate = Int((Double(summary.breaksCompleted) / Double(totalBreaks)) * 100)
            lines.append("\(summary.breaksCompleted) breaks completed (\(complianceRate)% compliance)")
        } else {
            lines.append("No breaks recorded")
        }

        // Week-over-week break comparison
        if let prevBreaks = summary.prevBreaksCompleted, prevBreaks > 0 {
            let delta = summary.breaksCompleted - prevBreaks
            if delta > 0 {
                lines.append("\(delta) more breaks than last week")
            } else if delta < 0 {
                lines.append("\(abs(delta)) fewer breaks than last week")
            } else {
                lines.append("Same break count as last week")
            }
        }

        // Health warning trend
        if let prevWarnings = summary.prevHealthWarnings {
            let delta = summary.healthWarnings - prevWarnings
            if delta < 0 {
                lines.append("\(abs(delta)) fewer health warnings — nice improvement!")
            } else if delta > 0 {
                lines.append("\(delta) more health warnings — try to break more often")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Scheduling

    private static let lastWeeklySummaryKey = "lastWeeklySummaryDate"

    /// Returns true if a weekly summary should be sent today.
    /// Triggers on Mondays, at most once per week.
    static func shouldSendWeeklySummary() -> Bool {
        let calendar = Calendar.current
        let today = Date()

        // Only send on Mondays (weekday 2 in Gregorian calendar)
        guard calendar.component(.weekday, from: today) == 2 else { return false }

        let todayString = dateFormatter.string(from: today)
        let lastSent = UserDefaults.standard.string(forKey: lastWeeklySummaryKey) ?? ""

        return lastSent != todayString
    }

    /// Mark that the weekly summary was sent today.
    static func markWeeklySummarySent() {
        let todayString = dateFormatter.string(from: Date())
        UserDefaults.standard.set(todayString, forKey: lastWeeklySummaryKey)
    }

    // MARK: - Streak Milestones

    /// Streak thresholds that trigger celebration notifications.
    static let milestones = [7, 14, 30, 60, 100, 200, 365]

    /// Returns the milestone value if the given streak just hit one, nil otherwise.
    static func checkMilestone(streak: Int) -> Int? {
        milestones.contains(streak) ? streak : nil
    }

    /// Celebration message for a streak milestone.
    static func milestoneMessage(days: Int) -> (title: String, body: String) {
        switch days {
        case 7:
            return (
                "1 Week Streak!",
                "7 days in a row. Your spine is thanking you. Keep it going!"
            )
        case 14:
            return (
                "2 Week Streak!",
                "14 consecutive days of breaks. You're building a real habit."
            )
        case 30:
            return (
                "1 Month Streak!",
                "30 days straight. Research shows habits formed at this point tend to stick. You're in the clear."
            )
        case 60:
            return (
                "60 Day Streak!",
                "Two months of consistent breaks. Your disc health is measurably better than when you started."
            )
        case 100:
            return (
                "100 Day Streak!",
                "Triple digits! You've completed breaks for 100 consecutive days. That's elite-level consistency."
            )
        case 200:
            return (
                "200 Day Streak!",
                "200 days. At this point, NOT taking breaks would feel wrong. That's the goal."
            )
        case 365:
            return (
                "1 Year Streak!",
                "365 days of standing up for your health. Literally. You've taken thousands of breaks this year."
            )
        default:
            return (
                "\(days) Day Streak!",
                "You've kept your streak alive for \(days) days. Impressive!"
            )
        }
    }

    // MARK: - Private

    private struct AggregatedMetrics {
        var breaksCompleted: Int = 0
        var breaksSkipped: Int = 0
        var breaksSnoozed: Int = 0
        var healthWarnings: Int = 0
        var totalWorkSeconds: TimeInterval = 0
        var totalBreakSeconds: TimeInterval = 0
        var daysActive: Int = 0
    }

    private static func aggregateMetrics(daysAgo range: Range<Int>) -> AggregatedMetrics {
        var metrics = AggregatedMetrics()

        for offset in range {
            guard let date = Calendar.current.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            let store = DailyTimelineStore(date: date)
            guard !store.events.isEmpty else { continue }

            metrics.daysActive += 1
            metrics.breaksCompleted += store.count(of: .breakCompleted)
            metrics.breaksSkipped += store.count(of: .breakSkipped)
            metrics.breaksSnoozed += store.count(of: .breakSnoozed)
            metrics.healthWarnings += store.count(of: .healthWarning)

            let durations = store.durationByKind()
            metrics.totalWorkSeconds += durations[.working] ?? 0
            metrics.totalBreakSeconds += durations[.onBreak] ?? 0
        }

        return metrics
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
