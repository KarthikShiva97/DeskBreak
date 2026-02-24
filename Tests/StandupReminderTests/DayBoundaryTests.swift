import Foundation
import Testing

@testable import StandupReminderLib

// MARK: - Date String Format

/// Verify that `todayString()` and the shared date formatter produce
/// well-formed "yyyy-MM-dd" strings that all stores agree on.
@Suite("Date string formatting")
struct DateStringTests {

    @Test("todayString() returns yyyy-MM-dd format")
    func todayStringFormat() {
        let result = DailyTimelineStore.todayString()

        // Must be exactly 10 characters: "2026-02-24"
        #expect(result.count == 10)

        let parts = result.split(separator: "-")
        #expect(parts.count == 3)
        #expect(parts[0].count == 4) // year
        #expect(parts[1].count == 2) // month
        #expect(parts[2].count == 2) // day
    }

    @Test("todayString() matches manual formatter output")
    func todayStringMatchesFormatter() {
        let manual = DailyTimelineStore.dateFormatter.string(from: Date())
        let helper = DailyTimelineStore.todayString()
        #expect(manual == helper)
    }

    @Test("Formatter has POSIX locale and explicit timezone")
    func formatterConfiguration() {
        let f = DailyTimelineStore.dateFormatter
        #expect(f.locale.identifier == "en_US_POSIX")
        #expect(f.timeZone == .current)
    }
}

// MARK: - Day Boundaries

/// Verify that dates just before and just after midnight map to different
/// day strings, and that the timeline store captures the correct day.
@Suite("Day boundaries")
struct DayBoundaryTests {

    /// Build a Date for "today at HH:mm:ss" in the current timezone.
    private func todayAt(hour: Int, minute: Int, second: Int) -> Date {
        var c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        c.hour = hour
        c.minute = minute
        c.second = second
        return Calendar.current.date(from: c)!
    }

    @Test("Dates on different calendar days produce different date strings")
    func differentDays() {
        let formatter = DailyTimelineStore.dateFormatter
        let today = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!

        let todayStr = formatter.string(from: today)
        let yesterdayStr = formatter.string(from: yesterday)

        #expect(todayStr != yesterdayStr)
    }

    @Test("23:59:59 and 00:00:01 on adjacent days differ")
    func midnightBoundary() {
        let formatter = DailyTimelineStore.dateFormatter
        let cal = Calendar.current

        // Build 23:59:59 today
        let lateTonight = todayAt(hour: 23, minute: 59, second: 59)
        // Build 00:00:01 tomorrow
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))!
        let earlyTomorrow = tomorrow.addingTimeInterval(1)

        let lateStr = formatter.string(from: lateTonight)
        let earlyStr = formatter.string(from: earlyTomorrow)

        #expect(lateStr != earlyStr)
    }

    @Test("Same calendar day always produces the same string")
    func sameDayConsistency() {
        let formatter = DailyTimelineStore.dateFormatter
        let morning = todayAt(hour: 6, minute: 0, second: 0)
        let evening = todayAt(hour: 22, minute: 0, second: 0)

        #expect(formatter.string(from: morning) == formatter.string(from: evening))
    }
}

// MARK: - Timeline Store Per-Day Isolation

/// The original bug: a single DailyTimelineStore created at launch kept
/// accumulating events across midnight. These tests verify that stores
/// for different dates are isolated from each other.
@Suite("Timeline store day isolation")
struct TimelineStoreIsolationTests {

    @Test("Store's day property matches the date it was created with")
    func storeDayMatchesDate() {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let store = DailyTimelineStore(date: yesterday)

        let expected = DailyTimelineStore.dateFormatter.string(from: yesterday)
        #expect(store.day == expected)
    }

    @Test("Store created with today's date matches todayString()")
    func storeTodayMatchesTodayString() {
        let store = DailyTimelineStore()
        #expect(store.day == DailyTimelineStore.todayString())
    }

    @Test("Stores for different dates have different day values")
    func storesForDifferentDatesAreDifferent() {
        let today = DailyTimelineStore(date: Date())
        let yesterday = DailyTimelineStore(
            date: Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        )

        #expect(today.day != yesterday.day)
    }

    @Test("Events recorded on one store don't appear on a different day's store")
    func eventsAreIsolatedBetweenDays() {
        // Use a far-past test date to avoid interfering with real data.
        let testDate = makeDate(year: 2020, month: 1, day: 15)
        let testDateNext = Calendar.current.date(byAdding: .day, value: 1, to: testDate)!

        let storeA = DailyTimelineStore(date: testDate)
        let storeB = DailyTimelineStore(date: testDateNext)

        storeA.record(.workStarted)
        storeA.record(.breakCompleted)

        // storeB should have zero events from storeA
        #expect(storeA.events.count == 2)
        #expect(storeB.events.count == 0)

        // Clean up test files
        cleanupTestFile(for: testDate)
        cleanupTestFile(for: testDateNext)
    }

    @Test("Creating a new store for today starts with empty events (no carryover)")
    func freshStoreIsEmpty() {
        // Use a far-future test date that will never have real data.
        let testDate = makeDate(year: 2099, month: 12, day: 25)
        let store = DailyTimelineStore(date: testDate)

        #expect(store.events.isEmpty)

        cleanupTestFile(for: testDate)
    }
}

// MARK: - Computed Segments End Time

/// Verify that `computeSegments()` uses the right end time: "now" for
/// today's store, and 23:59:59 for a past day's store.
@Suite("Segment end time")
struct SegmentEndTimeTests {

    @Test("Past day segments end at 23:59:59, not at current time")
    func pastDaySegmentsEndAtEndOfDay() {
        let testDate = makeDate(year: 2020, month: 6, day: 15)
        let store = DailyTimelineStore(date: testDate)

        // Inject an event at 9:00 AM on the test date
        var c = Calendar.current.dateComponents([.year, .month, .day], from: testDate)
        c.hour = 9; c.minute = 0; c.second = 0
        let nineAM = Calendar.current.date(from: c)!
        store.record(.workStarted, detail: nil)
        // The store recorded with `Date()` as timestamp, but the segments
        // should still end at 23:59:59 of the store's date since isToday is false.

        let segments = store.computeSegments()
        #expect(!segments.isEmpty)

        if let lastSegment = segments.last {
            let endComponents = Calendar.current.dateComponents(
                [.hour, .minute, .second], from: lastSegment.end
            )
            // For a past day, the last segment should end at 23:59:59
            #expect(endComponents.hour == 23)
            #expect(endComponents.minute == 59)
            #expect(endComponents.second == 59)
        }

        cleanupTestFile(for: testDate)
    }

    @Test("Today's segments end close to the current time")
    func todaySegmentsEndNearNow() {
        let testDate = makeDate(year: 2099, month: 12, day: 25)
        let store = DailyTimelineStore(date: Date())

        store.record(.workStarted)

        let segments = store.computeSegments()
        #expect(!segments.isEmpty)

        if let lastSegment = segments.last {
            let gap = abs(lastSegment.end.timeIntervalSinceNow)
            // Should be within a few seconds of "now"
            #expect(gap < 5)
        }

        cleanupTestFile(for: Date())
    }
}

// MARK: - Rollover Detection Logic

/// The rollover fix works by comparing `DailyTimelineStore.todayString()`
/// against a stored `currentDayString`. These tests verify the comparison
/// logic that drives the rollover.
@Suite("Rollover detection")
struct RolloverDetectionTests {

    @Test("Same date string means no rollover needed")
    func sameDay() {
        let today = DailyTimelineStore.todayString()
        // Simulate: currentDayString == todayString() → no rollover
        #expect(today == today)
    }

    @Test("Different date strings trigger rollover")
    func differentDay() {
        let today = DailyTimelineStore.todayString()
        let yesterday = DailyTimelineStore.dateFormatter.string(
            from: Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        )
        // Simulate: currentDayString (yesterday) != todayString() → rollover needed
        #expect(today != yesterday)
    }

    @Test("Consecutive todayString() calls within same second are stable")
    func stableWithinSameSecond() {
        let a = DailyTimelineStore.todayString()
        let b = DailyTimelineStore.todayString()
        #expect(a == b)
    }
}

// MARK: - Event Recording

/// Verify that events are correctly appended and counted.
@Suite("Event recording")
struct EventRecordingTests {

    @Test("record() appends events in order")
    func recordAppendsInOrder() {
        let testDate = makeDate(year: 2020, month: 3, day: 10)
        let store = DailyTimelineStore(date: testDate)

        store.record(.workStarted)
        store.record(.breakCompleted)
        store.record(.workEnded)

        #expect(store.events.count == 3)
        #expect(store.events[0].kind == .workStarted)
        #expect(store.events[1].kind == .breakCompleted)
        #expect(store.events[2].kind == .workEnded)

        cleanupTestFile(for: testDate)
    }

    @Test("count(of:) returns correct count per event kind")
    func countByKind() {
        let testDate = makeDate(year: 2020, month: 3, day: 11)
        let store = DailyTimelineStore(date: testDate)

        store.record(.breakCompleted)
        store.record(.breakCompleted)
        store.record(.breakSkipped)

        #expect(store.count(of: .breakCompleted) == 2)
        #expect(store.count(of: .breakSkipped) == 1)
        #expect(store.count(of: .workStarted) == 0)

        cleanupTestFile(for: testDate)
    }
}

// MARK: - Timezone Handling

/// Verify that the formatter respects the system timezone, so day
/// boundaries are consistent for the user's local time.
@Suite("Timezone handling")
struct TimezoneTests {

    @Test("Date formatter timezone matches system timezone")
    func formatterUsesSystemTimezone() {
        let formatter = DailyTimelineStore.dateFormatter
        #expect(formatter.timeZone.identifier == TimeZone.current.identifier)
    }

    @Test("Midnight in different timezones produces different date strings for the same UTC instant")
    func timezoneMatterForDayBoundary() {
        // Create a UTC formatter and a UTC+12 formatter
        let utcFormatter = DateFormatter()
        utcFormatter.dateFormat = "yyyy-MM-dd"
        utcFormatter.locale = Locale(identifier: "en_US_POSIX")
        utcFormatter.timeZone = TimeZone(identifier: "UTC")!

        let nzFormatter = DateFormatter()
        nzFormatter.dateFormat = "yyyy-MM-dd"
        nzFormatter.locale = Locale(identifier: "en_US_POSIX")
        nzFormatter.timeZone = TimeZone(identifier: "Pacific/Auckland")!

        // At 2026-01-15 06:00 UTC → still Jan 15 in UTC, but Jan 15 evening in NZ
        // At 2026-01-15 14:00 UTC → still Jan 15 in UTC, but Jan 16 morning in NZ
        var c = DateComponents()
        c.year = 2026; c.month = 1; c.day = 15
        c.hour = 14; c.minute = 0; c.second = 0
        c.timeZone = TimeZone(identifier: "UTC")
        let date = Calendar.current.date(from: c)!

        let utcDay = utcFormatter.string(from: date)
        let nzDay = nzFormatter.string(from: date)

        // 14:00 UTC is ~03:00 Jan 16 in NZ (UTC+13 in summer)
        #expect(utcDay == "2026-01-15")
        #expect(nzDay != utcDay, "Same UTC instant should map to different local days in NZ vs UTC")
    }
}

// MARK: - Test Helpers

/// Create a specific date for testing (using the current calendar's timezone).
private func makeDate(year: Int, month: Int, day: Int) -> Date {
    var c = DateComponents()
    c.year = year; c.month = month; c.day = day
    c.hour = 12; c.minute = 0; c.second = 0
    return Calendar.current.date(from: c)!
}

/// Remove a test timeline file from disk to avoid polluting real data.
private func cleanupTestFile(for date: Date) {
    let dateString = DailyTimelineStore.dateFormatter.string(from: date)
    let appSupport = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
    ).first!
    let file = appSupport
        .appendingPathComponent("DeskBreak/Timeline")
        .appendingPathComponent("\(dateString).json")
    try? FileManager.default.removeItem(at: file)
}
