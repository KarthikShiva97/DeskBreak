import XCTest
@testable import StandupReminderLib

final class DailyTimelineStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DailyTimelineTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func makeStore(dateString: String = "2025-06-15") -> DailyTimelineStore {
        let fileURL = tempDir.appendingPathComponent("\(dateString).json")
        return DailyTimelineStore(dateString: dateString, fileURL: fileURL)
    }

    // MARK: - Recording Events

    func testRecordEvent_addsToEvents() {
        let store = makeStore()
        XCTAssertTrue(store.events.isEmpty)

        store.record(.workStarted)
        XCTAssertEqual(store.events.count, 1)
        XCTAssertEqual(store.events[0].kind, .workStarted)
    }

    func testRecordEvent_preservesDetail() {
        let store = makeStore()
        store.record(.healthWarning, detail: "60 min continuous")
        XCTAssertEqual(store.events[0].detail, "60 min continuous")
    }

    func testRecordEvent_appendsInOrder() {
        let store = makeStore()
        store.record(.workStarted)
        store.record(.breakStarted)
        store.record(.breakCompleted)
        store.record(.workStarted)

        XCTAssertEqual(store.events.count, 4)
        XCTAssertEqual(store.events[0].kind, .workStarted)
        XCTAssertEqual(store.events[1].kind, .breakStarted)
        XCTAssertEqual(store.events[2].kind, .breakCompleted)
        XCTAssertEqual(store.events[3].kind, .workStarted)
    }

    // MARK: - Count of Kind

    func testCountOfKind_returnsCorrectCount() {
        let store = makeStore()
        store.record(.workStarted)
        store.record(.breakCompleted)
        store.record(.breakCompleted)
        store.record(.breakSkipped)
        store.record(.breakCompleted)

        XCTAssertEqual(store.count(of: .breakCompleted), 3)
        XCTAssertEqual(store.count(of: .breakSkipped), 1)
        XCTAssertEqual(store.count(of: .workStarted), 1)
        XCTAssertEqual(store.count(of: .healthWarning), 0)
    }

    // MARK: - Compute Segments

    func testComputeSegments_emptyEvents_returnsEmpty() {
        let store = makeStore()
        let segments = store.computeSegments()
        XCTAssertTrue(segments.isEmpty)
    }

    func testComputeSegments_singleWorkCycle() {
        let store = makeStore()
        store.record(.workStarted)
        store.record(.workEnded)

        let segments = store.computeSegments()

        // Should have at least: idle → working → idle (based on events)
        // workStarted transitions from idle to working
        // workEnded transitions from working to idle
        XCTAssertGreaterThanOrEqual(segments.count, 1)

        // The first transition creates a segment: the initial idle up to workStarted
        // may have zero duration, then working from workStarted to workEnded
        let workingSegments = segments.filter { $0.kind == .working }
        XCTAssertEqual(workingSegments.count, 1, "Should have exactly one working segment")
    }

    func testComputeSegments_breakCycle() {
        let store = makeStore()
        store.record(.workStarted)
        store.record(.breakStarted)
        store.record(.breakCompleted)

        let segments = store.computeSegments()
        let kinds = segments.map(\.kind)

        XCTAssertTrue(kinds.contains(.working), "Should have a working segment")
        XCTAssertTrue(kinds.contains(.onBreak), "Should have a break segment")
    }

    func testComputeSegments_meetingCycle() {
        let store = makeStore()
        store.record(.workStarted)
        store.record(.meetingStarted)
        store.record(.meetingEnded)

        let segments = store.computeSegments()
        let kinds = segments.map(\.kind)

        XCTAssertTrue(kinds.contains(.working), "Should have working segment before meeting")
        XCTAssertTrue(kinds.contains(.inMeeting), "Should have meeting segment")
    }

    func testComputeSegments_disabledCycle() {
        let store = makeStore()
        store.record(.workStarted)
        store.record(.disabled)
        store.record(.resumed)

        let segments = store.computeSegments()
        let kinds = segments.map(\.kind)

        XCTAssertTrue(kinds.contains(.disabled), "Should have disabled segment")
    }

    func testComputeSegments_snoozeDoesNotCreateNewSegment() {
        let store = makeStore()
        store.record(.workStarted)
        store.record(.breakSnoozed)

        let segments = store.computeSegments()
        // Snooze should not change the segment kind — workStarted sets it to .working
        // and breakSnoozed returns nil (no transition)
        let workingSegments = segments.filter { $0.kind == .working }
        XCTAssertEqual(workingSegments.count, 1,
                       "Snooze should not create a new segment")
    }

    func testComputeSegments_healthWarningDoesNotCreateNewSegment() {
        let store = makeStore()
        store.record(.workStarted)
        store.record(.healthWarning)

        let segments = store.computeSegments()
        let workingSegments = segments.filter { $0.kind == .working }
        XCTAssertEqual(workingSegments.count, 1,
                       "Health warning should not create a new segment")
    }

    func testComputeSegments_segmentsHavePositiveDuration() {
        let store = makeStore()
        store.record(.workStarted)
        // Add a small delay to ensure different timestamps
        Thread.sleep(forTimeInterval: 0.01)
        store.record(.breakStarted)
        Thread.sleep(forTimeInterval: 0.01)
        store.record(.breakCompleted)

        let segments = store.computeSegments()
        for segment in segments {
            XCTAssertGreaterThanOrEqual(segment.duration, 0,
                                         "Segment duration should be non-negative")
        }
    }

    // MARK: - Duration By Kind

    func testDurationByKind_aggregatesDurations() {
        let store = makeStore()
        store.record(.workStarted)
        Thread.sleep(forTimeInterval: 0.05)
        store.record(.breakStarted)
        Thread.sleep(forTimeInterval: 0.05)
        store.record(.breakCompleted)

        let durations = store.durationByKind()
        // Working and break durations should both be present and positive
        XCTAssertNotNil(durations[.working])
        XCTAssertNotNil(durations[.onBreak])
    }

    // MARK: - Persistence

    func testPersistence_roundTrip() {
        let dateStr = "2025-06-15"
        let fileURL = tempDir.appendingPathComponent("\(dateStr).json")
        let store1 = DailyTimelineStore(dateString: dateStr, fileURL: fileURL)
        store1.record(.workStarted)
        store1.record(.breakCompleted)
        store1.record(.healthWarning, detail: "90 min (urgent)")

        // Create a new store pointing to the same file
        let store2 = DailyTimelineStore(dateString: dateStr, fileURL: fileURL)
        XCTAssertEqual(store2.events.count, 3, "Persisted events should be reloaded")
        XCTAssertEqual(store2.events[0].kind, .workStarted)
        XCTAssertEqual(store2.events[1].kind, .breakCompleted)
        XCTAssertEqual(store2.events[2].kind, .healthWarning)
        XCTAssertEqual(store2.events[2].detail, "90 min (urgent)")
    }

    func testPersistence_emptyFile_loadsEmpty() {
        let store = DailyTimelineStore(
            dateString: "2025-12-25",
            fileURL: tempDir.appendingPathComponent("2025-12-25.json")
        )
        XCTAssertTrue(store.events.isEmpty)
    }

    // MARK: - Day Property

    func testDay_matchesDateString() {
        let store = makeStore(dateString: "2025-08-20")
        XCTAssertEqual(store.day, "2025-08-20")
    }

    // MARK: - TimelineEvent Properties

    func testTimelineEvent_hasUniqueID() {
        let e1 = TimelineEvent(kind: .workStarted)
        let e2 = TimelineEvent(kind: .workStarted)
        XCTAssertNotEqual(e1.id, e2.id)
    }

    func testTimelineEvent_timestampIsNow() {
        let before = Date()
        let event = TimelineEvent(kind: .workStarted)
        let after = Date()
        XCTAssertGreaterThanOrEqual(event.timestamp, before)
        XCTAssertLessThanOrEqual(event.timestamp, after)
    }

    func testTimelineEvent_customTimestamp() {
        let custom = Date(timeIntervalSince1970: 1000000)
        let event = TimelineEvent(kind: .breakCompleted, timestamp: custom)
        XCTAssertEqual(event.timestamp, custom)
    }

    func testTimelineEvent_detailDefaultsToNil() {
        let event = TimelineEvent(kind: .workStarted)
        XCTAssertNil(event.detail)
    }

    // MARK: - TimelineEventKind Encoding

    func testTimelineEventKind_codable() throws {
        let kinds: [TimelineEventKind] = [
            .workStarted, .workEnded, .breakStarted, .breakCompleted,
            .breakSkipped, .breakSnoozed, .meetingStarted, .meetingEnded,
            .healthWarning, .disabled, .resumed, .sessionReset
        ]
        for kind in kinds {
            let data = try JSONEncoder().encode(kind)
            let decoded = try JSONDecoder().decode(TimelineEventKind.self, from: data)
            XCTAssertEqual(decoded, kind, "Round-trip encoding failed for \(kind)")
        }
    }

    func testTimelineEventKind_rawValues() {
        XCTAssertEqual(TimelineEventKind.workStarted.rawValue, "workStarted")
        XCTAssertEqual(TimelineEventKind.breakStarted.rawValue, "breakStarted")
        XCTAssertEqual(TimelineEventKind.breakCompleted.rawValue, "breakCompleted")
        XCTAssertEqual(TimelineEventKind.breakSkipped.rawValue, "breakSkipped")
        XCTAssertEqual(TimelineEventKind.meetingStarted.rawValue, "meetingStarted")
        XCTAssertEqual(TimelineEventKind.healthWarning.rawValue, "healthWarning")
        XCTAssertEqual(TimelineEventKind.disabled.rawValue, "disabled")
        XCTAssertEqual(TimelineEventKind.resumed.rawValue, "resumed")
        XCTAssertEqual(TimelineEventKind.sessionReset.rawValue, "sessionReset")
    }

    // MARK: - Full Workflow

    func testFullWorkday_segmentsAreConsistent() {
        let store = makeStore()

        // Simulate: start work → snooze → health warning → break → back to work → idle
        store.record(.workStarted)
        store.record(.breakSnoozed)
        store.record(.healthWarning, detail: "60 min")
        store.record(.breakStarted)
        store.record(.breakCompleted)
        store.record(.workStarted)
        store.record(.workEnded)

        let segments = store.computeSegments()

        // Verify no overlapping segments
        for i in 1..<segments.count {
            XCTAssertGreaterThanOrEqual(segments[i].start, segments[i-1].end,
                                         "Segments should not overlap")
        }

        // Verify segment kinds are in the expected transitions
        let kinds = segments.map(\.kind)
        XCTAssertTrue(kinds.contains(.working))
        XCTAssertTrue(kinds.contains(.onBreak))

        // Count events
        XCTAssertEqual(store.count(of: .breakCompleted), 1)
        XCTAssertEqual(store.count(of: .breakSnoozed), 1)
        XCTAssertEqual(store.count(of: .healthWarning), 1)
    }
}
