import XCTest
@testable import StandupReminderLib

final class DailyStatsStoreTests: XCTestCase {
    private var tempDir: URL!
    private var store: DailyStatsStore!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DailyStatsStoreTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("test-daily-stats.json")
        store = DailyStatsStore(fileURL: fileURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Today Record

    func testTodayRecord_createsDefaultRecord() {
        let record = store.todayRecord()
        XCTAssertEqual(record.breaksCompleted, 0)
        XCTAssertEqual(record.breaksSkipped, 0)
        XCTAssertEqual(record.breaksSnoozed, 0)
        XCTAssertEqual(record.healthWarningsReceived, 0)
        XCTAssertEqual(record.totalWorkSeconds, 0)
        XCTAssertEqual(record.longestContinuousSittingSeconds, 0)
    }

    func testTodayRecord_dateMatchesToday() {
        let record = store.todayRecord()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let expected = formatter.string(from: Date())
        XCTAssertEqual(record.date, expected)
    }

    // MARK: - Mutations

    func testRecordBreakCompleted_increments() {
        store.recordBreakCompleted()
        store.recordBreakCompleted()
        XCTAssertEqual(store.todayRecord().breaksCompleted, 2)
    }

    func testRecordBreakSkipped_increments() {
        store.recordBreakSkipped()
        XCTAssertEqual(store.todayRecord().breaksSkipped, 1)
    }

    func testRecordBreakSnoozed_increments() {
        store.recordBreakSnoozed()
        store.recordBreakSnoozed()
        store.recordBreakSnoozed()
        XCTAssertEqual(store.todayRecord().breaksSnoozed, 3)
    }

    func testRecordHealthWarning_increments() {
        store.recordHealthWarning()
        XCTAssertEqual(store.todayRecord().healthWarningsReceived, 1)
    }

    func testUpdateTotalWorkSeconds_replacesValue() {
        store.updateTotalWorkSeconds(100)
        XCTAssertEqual(store.todayRecord().totalWorkSeconds, 100)
        store.updateTotalWorkSeconds(200)
        XCTAssertEqual(store.todayRecord().totalWorkSeconds, 200,
                       "Total work seconds should be replaced, not accumulated")
    }

    func testUpdateLongestContinuousSitting_maxSemantics() {
        store.updateLongestContinuousSitting(100)
        XCTAssertEqual(store.todayRecord().longestContinuousSittingSeconds, 100)
        store.updateLongestContinuousSitting(50)
        XCTAssertEqual(store.todayRecord().longestContinuousSittingSeconds, 100,
                       "Should keep the higher value")
        store.updateLongestContinuousSitting(200)
        XCTAssertEqual(store.todayRecord().longestContinuousSittingSeconds, 200)
    }

    // MARK: - Seed

    func testSeedToday_setsAbsoluteValues() {
        store.seedToday(
            breaksCompleted: 5,
            breaksSkipped: 2,
            breaksSnoozed: 1,
            healthWarnings: 3,
            totalWorkSeconds: 7200
        )
        let record = store.todayRecord()
        XCTAssertEqual(record.breaksCompleted, 5)
        XCTAssertEqual(record.breaksSkipped, 2)
        XCTAssertEqual(record.breaksSnoozed, 1)
        XCTAssertEqual(record.healthWarningsReceived, 3)
        XCTAssertEqual(record.totalWorkSeconds, 7200)
    }

    func testSeedToday_overwritesPreviousValues() {
        store.recordBreakCompleted()
        store.recordBreakCompleted()
        XCTAssertEqual(store.todayRecord().breaksCompleted, 2)

        store.seedToday(
            breaksCompleted: 10,
            breaksSkipped: 0,
            breaksSnoozed: 0,
            healthWarnings: 0,
            totalWorkSeconds: 0
        )
        XCTAssertEqual(store.todayRecord().breaksCompleted, 10,
                       "Seed should overwrite, not accumulate")
    }

    // MARK: - Record Lookups

    func testRecord_forNonexistentDate_returnsNil() {
        XCTAssertNil(store.record(for: "1999-01-01"))
    }

    func testRecord_forExistingDate() {
        store.recordBreakCompleted() // Creates today's record
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let today = formatter.string(from: Date())
        XCTAssertNotNil(store.record(for: today))
    }

    // MARK: - All Records

    func testAllRecords_sortedByDate() {
        // Seed records for different dates by manipulating the store directly
        store.recordBreakCompleted()
        let records = store.allRecords()
        // At least today should be present
        XCTAssertGreaterThanOrEqual(records.count, 1)

        // Verify sorting
        for i in 1..<records.count {
            XCTAssertLessThanOrEqual(records[i-1].date, records[i].date,
                                     "Records should be sorted by date ascending")
        }
    }

    // MARK: - Persistence Round-Trip

    func testFlushAndReload_preservesData() {
        store.recordBreakCompleted()
        store.recordBreakCompleted()
        store.recordBreakSkipped()
        store.updateTotalWorkSeconds(3600)
        store.updateLongestContinuousSitting(1800)
        store.flush()

        // Create a new store pointing to the same file
        let fileURL = tempDir.appendingPathComponent("test-daily-stats.json")
        let reloaded = DailyStatsStore(fileURL: fileURL)
        let record = reloaded.todayRecord()

        XCTAssertEqual(record.breaksCompleted, 2)
        XCTAssertEqual(record.breaksSkipped, 1)
        XCTAssertEqual(record.totalWorkSeconds, 3600)
        XCTAssertEqual(record.longestContinuousSittingSeconds, 1800)
    }

    func testFlushWithNoChanges_doesNotCrash() {
        store.flush()
        // Should be a no-op, not crash
    }

    // MARK: - Date Range Queries

    func testRecordsDateRange_returnsMatchingRecords() {
        store.recordBreakCompleted()

        let today = Calendar.current.startOfDay(for: Date())
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        let records = store.records(from: today, to: tomorrow)
        // Today should be included
        XCTAssertGreaterThanOrEqual(records.count, 1)
    }

    func testRecordsDateRange_emptyForFutureDates() {
        let nextWeek = Calendar.current.date(byAdding: .day, value: 7, to: Date())!
        let nextWeekEnd = Calendar.current.date(byAdding: .day, value: 14, to: Date())!
        let records = store.records(from: nextWeek, to: nextWeekEnd)
        XCTAssertTrue(records.isEmpty, "Future date range should have no records")
    }

    // MARK: - DailyStatsRecord Identity

    func testDailyStatsRecord_idIsDate() {
        let record = DailyStatsRecord(date: "2025-03-15")
        XCTAssertEqual(record.id, "2025-03-15")
    }

    func testDailyStatsRecord_defaults() {
        let record = DailyStatsRecord(date: "2025-01-01")
        XCTAssertEqual(record.breaksCompleted, 0)
        XCTAssertEqual(record.breaksSkipped, 0)
        XCTAssertEqual(record.breaksSnoozed, 0)
        XCTAssertEqual(record.healthWarningsReceived, 0)
        XCTAssertEqual(record.longestContinuousSittingSeconds, 0)
        XCTAssertEqual(record.totalWorkSeconds, 0)
    }
}
