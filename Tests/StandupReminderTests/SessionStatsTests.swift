import XCTest
@testable import StandupReminderLib

final class SessionStatsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var stats: SessionStats!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "SessionStatsTests.\(UUID().uuidString)")!
        stats = SessionStats(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaults.suiteName ?? "")
        super.tearDown()
    }

    // MARK: - Break Recording

    func testRecordBreakCompleted_incrementsCounter() {
        XCTAssertEqual(stats.breaksCompleted, 0)
        stats.recordBreakCompleted()
        XCTAssertEqual(stats.breaksCompleted, 1)
        stats.recordBreakCompleted()
        XCTAssertEqual(stats.breaksCompleted, 2)
    }

    func testRecordBreakSkipped_incrementsCounter() {
        XCTAssertEqual(stats.breaksSkipped, 0)
        stats.recordBreakSkipped()
        XCTAssertEqual(stats.breaksSkipped, 1)
    }

    func testRecordBreakSnoozed_incrementsCounter() {
        XCTAssertEqual(stats.breaksSnoozed, 0)
        stats.recordBreakSnoozed()
        XCTAssertEqual(stats.breaksSnoozed, 1)
    }

    func testRecordHealthWarning_incrementsCounter() {
        XCTAssertEqual(stats.healthWarningsReceived, 0)
        stats.recordHealthWarning()
        XCTAssertEqual(stats.healthWarningsReceived, 1)
    }

    func testRecordBreakCompleted_incrementsAllTimeTotal() {
        let before = stats.totalBreaksAllTime
        stats.recordBreakCompleted()
        XCTAssertEqual(stats.totalBreaksAllTime, before + 1)
    }

    // MARK: - Longest Continuous Sitting

    func testUpdateLongestContinuousSitting_updatesWhenHigher() {
        stats.updateLongestContinuousSitting(100)
        XCTAssertEqual(stats.longestContinuousSittingSeconds, 100)
        stats.updateLongestContinuousSitting(200)
        XCTAssertEqual(stats.longestContinuousSittingSeconds, 200)
    }

    func testUpdateLongestContinuousSitting_doesNotUpdateWhenLower() {
        stats.updateLongestContinuousSitting(200)
        stats.updateLongestContinuousSitting(100)
        XCTAssertEqual(stats.longestContinuousSittingSeconds, 200)
    }

    func testUpdateLongestContinuousSitting_equalValueIsNoOp() {
        stats.updateLongestContinuousSitting(100)
        stats.updateLongestContinuousSitting(100)
        XCTAssertEqual(stats.longestContinuousSittingSeconds, 100)
    }

    // MARK: - Reset Session

    func testResetSession_clearsAllCounters() {
        stats.recordBreakCompleted()
        stats.recordBreakSkipped()
        stats.recordBreakSnoozed()
        stats.recordHealthWarning()
        stats.updateLongestContinuousSitting(3600)

        stats.resetSession()

        XCTAssertEqual(stats.breaksCompleted, 0)
        XCTAssertEqual(stats.breaksSkipped, 0)
        XCTAssertEqual(stats.breaksSnoozed, 0)
        XCTAssertEqual(stats.healthWarningsReceived, 0)
        XCTAssertEqual(stats.longestContinuousSittingSeconds, 0)
    }

    func testResetSession_doesNotAffectAllTimeTotal() {
        stats.recordBreakCompleted()
        stats.recordBreakCompleted()
        let allTimeBefore = stats.totalBreaksAllTime

        stats.resetSession()

        XCTAssertEqual(stats.totalBreaksAllTime, allTimeBefore,
                       "All-time total should survive session reset")
    }

    // MARK: - Session Summary

    func testSessionSummary_minutesOnly() {
        stats.recordBreakCompleted()
        let summary = stats.sessionSummary(totalWorkSeconds: 1800) // 30m
        XCTAssertTrue(summary.contains("30m worked"))
        XCTAssertTrue(summary.contains("Breaks completed: 1"))
    }

    func testSessionSummary_hoursAndMinutes() {
        let summary = stats.sessionSummary(totalWorkSeconds: 5400) // 1h 30m
        XCTAssertTrue(summary.contains("1h 30m worked"))
    }

    func testSessionSummary_includesSkippedAndSnoozed() {
        stats.recordBreakSkipped()
        stats.recordBreakSnoozed()
        stats.recordBreakSnoozed()
        let summary = stats.sessionSummary(totalWorkSeconds: 600)
        XCTAssertTrue(summary.contains("skipped early: 1"))
        XCTAssertTrue(summary.contains("snoozed: 2"))
    }

    func testSessionSummary_includesHealthWarnings() {
        stats.recordHealthWarning()
        stats.recordHealthWarning()
        let summary = stats.sessionSummary(totalWorkSeconds: 7200)
        XCTAssertTrue(summary.contains("Health warnings: 2"))
    }

    func testSessionSummary_longSittingStreakIncluded() {
        stats.updateLongestContinuousSitting(4500) // 1h 15m
        let summary = stats.sessionSummary(totalWorkSeconds: 4500)
        XCTAssertTrue(summary.contains("Longest sitting streak: 1h 15m"))
    }

    func testSessionSummary_shortSittingStreakOmitted() {
        stats.updateLongestContinuousSitting(1800) // 30m — below 1h threshold
        let summary = stats.sessionSummary(totalWorkSeconds: 1800)
        XCTAssertFalse(summary.contains("Longest sitting"))
    }

    // MARK: - Daily Streak

    func testDailyStreak_startsAtZeroForNewUser() {
        XCTAssertEqual(stats.dailyStreak, 0)
    }

    func testDailyStreak_firstBreakSetsStreakToOne() {
        stats.recordBreakCompleted()
        XCTAssertEqual(stats.dailyStreak, 1)
    }

    func testDailyStreak_noDoubleIncrementSameDay() {
        stats.recordBreakCompleted()
        stats.recordBreakCompleted()
        stats.recordBreakCompleted()
        XCTAssertEqual(stats.dailyStreak, 1,
                       "Multiple breaks on the same day should not inflate the streak")
    }

    func testDailyStreak_resetsWhenGapDetected() {
        // Simulate: last active was 3 days ago
        let threeDaysAgo = Calendar.current.date(byAdding: .day, value: -3, to: Date())!
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        defaults.set(formatter.string(from: threeDaysAgo), forKey: "lastActiveDate")
        defaults.set(5, forKey: "dailyStreak")

        // Re-create stats — init should detect the gap and reset
        let freshStats = SessionStats(defaults: defaults)
        XCTAssertEqual(freshStats.dailyStreak, 0,
                       "Streak should reset when there's a gap > 1 day")
    }

    func testDailyStreak_continuedFromYesterday() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        defaults.set(formatter.string(from: yesterday), forKey: "lastActiveDate")
        defaults.set(3, forKey: "dailyStreak")

        // Re-create stats — init should not reset since yesterday is adjacent
        let freshStats = SessionStats(defaults: defaults)
        XCTAssertEqual(freshStats.dailyStreak, 3,
                       "Streak should carry forward from yesterday")

        // Now complete a break — streak should increment to 4
        freshStats.recordBreakCompleted()
        XCTAssertEqual(freshStats.dailyStreak, 4)
    }

    // MARK: - Restore From DailyStatsRecord

    func testRestoreFromDailyStats() {
        let record = DailyStatsRecord(
            date: "2025-01-15",
            breaksCompleted: 5,
            breaksSkipped: 2,
            breaksSnoozed: 3,
            healthWarningsReceived: 1,
            longestContinuousSittingSeconds: 4500,
            totalWorkSeconds: 18000
        )
        stats.restoreFromDailyStats(record)

        XCTAssertEqual(stats.breaksCompleted, 5)
        XCTAssertEqual(stats.breaksSkipped, 2)
        XCTAssertEqual(stats.breaksSnoozed, 3)
        XCTAssertEqual(stats.healthWarningsReceived, 1)
        XCTAssertEqual(stats.longestContinuousSittingSeconds, 4500)
    }

    // MARK: - Edge Cases

    func testSessionSummary_zeroWorkTime() {
        let summary = stats.sessionSummary(totalWorkSeconds: 0)
        XCTAssertTrue(summary.contains("0m worked"))
    }

    func testDailyStreak_pluralization() {
        defaults.set(1, forKey: "dailyStreak")
        let summary = stats.sessionSummary(totalWorkSeconds: 60)
        XCTAssertTrue(summary.contains("1 day"), "Singular 'day' for streak of 1")
        XCTAssertFalse(summary.contains("1 days"))
    }

    func testDailyStreak_pluralizationMultiple() {
        defaults.set(5, forKey: "dailyStreak")
        let summary = stats.sessionSummary(totalWorkSeconds: 60)
        XCTAssertTrue(summary.contains("5 days"), "Plural 'days' for streak > 1")
    }
}
