import XCTest
@testable import StandupReminderCore

final class SessionStatsTests: XCTestCase {
    var sut: SessionStats!

    override func setUp() {
        super.setUp()
        sut = SessionStats()
        sut.resetSession()
    }

    // MARK: - Initial State

    func testInitialState_allZeros() {
        XCTAssertEqual(sut.breaksCompleted, 0)
        XCTAssertEqual(sut.breaksSkipped, 0)
        XCTAssertEqual(sut.breaksSnoozed, 0)
        XCTAssertEqual(sut.healthWarningsReceived, 0)
        XCTAssertEqual(sut.longestContinuousSittingSeconds, 0)
    }

    // MARK: - Recording

    func testRecordBreakCompleted_increments() {
        sut.recordBreakCompleted()
        XCTAssertEqual(sut.breaksCompleted, 1)

        sut.recordBreakCompleted()
        XCTAssertEqual(sut.breaksCompleted, 2)
    }

    func testRecordBreakSkipped_increments() {
        sut.recordBreakSkipped()
        XCTAssertEqual(sut.breaksSkipped, 1)
    }

    func testRecordBreakSnoozed_increments() {
        sut.recordBreakSnoozed()
        XCTAssertEqual(sut.breaksSnoozed, 1)
    }

    func testRecordHealthWarning_increments() {
        sut.recordHealthWarning()
        XCTAssertEqual(sut.healthWarningsReceived, 1)

        sut.recordHealthWarning()
        XCTAssertEqual(sut.healthWarningsReceived, 2)
    }

    // MARK: - Longest Sitting

    func testUpdateLongestContinuousSitting_higherValue_updates() {
        sut.updateLongestContinuousSitting(100)
        XCTAssertEqual(sut.longestContinuousSittingSeconds, 100)

        sut.updateLongestContinuousSitting(200)
        XCTAssertEqual(sut.longestContinuousSittingSeconds, 200)
    }

    func testUpdateLongestContinuousSitting_lowerValue_noChange() {
        sut.updateLongestContinuousSitting(200)
        sut.updateLongestContinuousSitting(100)
        XCTAssertEqual(sut.longestContinuousSittingSeconds, 200)
    }

    func testUpdateLongestContinuousSitting_equalValue_noChange() {
        sut.updateLongestContinuousSitting(200)
        sut.updateLongestContinuousSitting(200)
        XCTAssertEqual(sut.longestContinuousSittingSeconds, 200)
    }

    // MARK: - Reset

    func testResetSession_clearsAllCounters() {
        sut.recordBreakCompleted()
        sut.recordBreakSkipped()
        sut.recordBreakSnoozed()
        sut.recordHealthWarning()
        sut.updateLongestContinuousSitting(500)

        sut.resetSession()

        XCTAssertEqual(sut.breaksCompleted, 0)
        XCTAssertEqual(sut.breaksSkipped, 0)
        XCTAssertEqual(sut.breaksSnoozed, 0)
        XCTAssertEqual(sut.healthWarningsReceived, 0)
        XCTAssertEqual(sut.longestContinuousSittingSeconds, 0)
    }

    // MARK: - Restore from DailyStats

    func testRestoreFromDailyStats_setsAllFields() {
        var record = DailyStatsRecord(date: "2025-01-01")
        record.breaksCompleted = 5
        record.breaksSkipped = 2
        record.breaksSnoozed = 3
        record.healthWarningsReceived = 1
        record.longestContinuousSittingSeconds = 7200

        sut.restoreFromDailyStats(record)

        XCTAssertEqual(sut.breaksCompleted, 5)
        XCTAssertEqual(sut.breaksSkipped, 2)
        XCTAssertEqual(sut.breaksSnoozed, 3)
        XCTAssertEqual(sut.healthWarningsReceived, 1)
        XCTAssertEqual(sut.longestContinuousSittingSeconds, 7200)
    }

    // MARK: - Session Summary

    func testSessionSummary_shortSession_minuteFormat() {
        let summary = sut.sessionSummary(totalWorkSeconds: 1500)  // 25 min
        XCTAssertTrue(summary.contains("Session: 25m worked"))
        XCTAssertTrue(summary.contains("Breaks completed: 0"))
    }

    func testSessionSummary_longSession_hourFormat() {
        let summary = sut.sessionSummary(totalWorkSeconds: 7200)  // 2 hours
        XCTAssertTrue(summary.contains("Session: 2h 0m worked"))
    }

    func testSessionSummary_withSkipsAndSnoozes() {
        sut.recordBreakCompleted()
        sut.recordBreakCompleted()
        sut.recordBreakSkipped()
        sut.recordBreakSnoozed()
        sut.recordBreakSnoozed()

        let summary = sut.sessionSummary(totalWorkSeconds: 3600)
        XCTAssertTrue(summary.contains("Breaks completed: 2"))
        XCTAssertTrue(summary.contains("Breaks skipped early: 1"))
        XCTAssertTrue(summary.contains("Breaks snoozed: 2"))
    }

    func testSessionSummary_withHealthWarnings() {
        sut.recordHealthWarning()
        sut.recordHealthWarning()

        let summary = sut.sessionSummary(totalWorkSeconds: 3600)
        XCTAssertTrue(summary.contains("Health warnings: 2"))
    }

    func testSessionSummary_withLongSittingStreak() {
        sut.updateLongestContinuousSitting(5400)  // 1h 30m
        let summary = sut.sessionSummary(totalWorkSeconds: 7200)
        XCTAssertTrue(summary.contains("Longest sitting streak: 1h 30m"))
    }

    func testSessionSummary_shortSitting_notShown() {
        sut.updateLongestContinuousSitting(1800)  // 30 min (< 1 hour)
        let summary = sut.sessionSummary(totalWorkSeconds: 3600)
        XCTAssertFalse(summary.contains("Longest sitting"))
    }

    func testSessionSummary_noSkips_notShown() {
        let summary = sut.sessionSummary(totalWorkSeconds: 1500)
        XCTAssertFalse(summary.contains("skipped"))
        XCTAssertFalse(summary.contains("snoozed"))
    }
}
