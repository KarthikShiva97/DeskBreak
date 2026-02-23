import XCTest
@testable import StandupReminderCore

final class DailyTimelineStoreTests: XCTestCase {

    // Use a far-past date so tests don't collide with real today data
    private func makeStore() -> DailyTimelineStore {
        DailyTimelineStore(date: Date(timeIntervalSince1970: 0))  // 1970-01-01
    }

    // MARK: - Record Events

    func testRecord_appendsEvent() {
        let store = makeStore()
        XCTAssertEqual(store.events.count, 0)

        store.record(.workStarted)
        XCTAssertEqual(store.events.count, 1)
        XCTAssertEqual(store.events[0].kind, .workStarted)
    }

    func testRecord_appendsMultipleEvents() {
        let store = makeStore()
        store.record(.workStarted)
        store.record(.workEnded)
        store.record(.breakCompleted)

        XCTAssertEqual(store.events.count, 3)
        XCTAssertEqual(store.events[0].kind, .workStarted)
        XCTAssertEqual(store.events[1].kind, .workEnded)
        XCTAssertEqual(store.events[2].kind, .breakCompleted)
    }

    func testRecord_preservesDetail() {
        let store = makeStore()
        store.record(.healthWarning, detail: "60 min")
        XCTAssertEqual(store.events[0].detail, "60 min")
    }

    func testRecord_nilDetailByDefault() {
        let store = makeStore()
        store.record(.workStarted)
        XCTAssertNil(store.events[0].detail)
    }

    // MARK: - Count

    func testCountOfKind_matchesRecordedEvents() {
        let store = makeStore()
        store.record(.breakCompleted)
        store.record(.breakCompleted)
        store.record(.breakSkipped)
        store.record(.breakCompleted)

        XCTAssertEqual(store.count(of: .breakCompleted), 3)
        XCTAssertEqual(store.count(of: .breakSkipped), 1)
        XCTAssertEqual(store.count(of: .workStarted), 0)
    }

    // MARK: - Segment Kind Mapping

    func testSegmentKind_workStarted_returnsWorking() {
        let store = makeStore()
        XCTAssertEqual(store.segmentKind(for: .workStarted), .working)
    }

    func testSegmentKind_workEnded_returnsIdle() {
        let store = makeStore()
        XCTAssertEqual(store.segmentKind(for: .workEnded), .idle)
    }

    func testSegmentKind_meetingStarted_returnsInMeeting() {
        let store = makeStore()
        XCTAssertEqual(store.segmentKind(for: .meetingStarted), .inMeeting)
    }

    func testSegmentKind_meetingEnded_returnsWorking() {
        let store = makeStore()
        XCTAssertEqual(store.segmentKind(for: .meetingEnded), .working)
    }

    func testSegmentKind_breakCompleted_returnsWorking() {
        let store = makeStore()
        XCTAssertEqual(store.segmentKind(for: .breakCompleted), .working)
    }

    func testSegmentKind_breakSkipped_returnsWorking() {
        let store = makeStore()
        XCTAssertEqual(store.segmentKind(for: .breakSkipped), .working)
    }

    func testSegmentKind_disabled_returnsDisabled() {
        let store = makeStore()
        XCTAssertEqual(store.segmentKind(for: .disabled), .disabled)
    }

    func testSegmentKind_resumed_returnsWorking() {
        let store = makeStore()
        XCTAssertEqual(store.segmentKind(for: .resumed), .working)
    }

    func testSegmentKind_sessionReset_returnsIdle() {
        let store = makeStore()
        XCTAssertEqual(store.segmentKind(for: .sessionReset), .idle)
    }

    func testSegmentKind_breakSnoozed_returnsNil() {
        let store = makeStore()
        XCTAssertNil(store.segmentKind(for: .breakSnoozed))
    }

    func testSegmentKind_healthWarning_returnsNil() {
        let store = makeStore()
        XCTAssertNil(store.segmentKind(for: .healthWarning))
    }

    // MARK: - Compute Segments

    func testComputeSegments_emptyTimeline_returnsEmpty() {
        let store = makeStore()
        XCTAssertTrue(store.computeSegments().isEmpty)
    }

    func testComputeSegments_singleWorkSession() {
        let store = makeStore()
        store.record(.workStarted)

        let segments = store.computeSegments()
        // Should have at least one segment (the initial idle → working transition)
        XCTAssertFalse(segments.isEmpty)
        // The last segment should be working (workStarted transitions to working)
        XCTAssertEqual(segments.last?.kind, .working)
    }

    func testComputeSegments_meetingInMiddleOfWork() {
        let store = makeStore()
        store.record(.workStarted)
        store.record(.meetingStarted)
        store.record(.meetingEnded)

        let segments = store.computeSegments()
        let kinds = segments.map { $0.kind }
        // Should transition: idle → working → inMeeting → working
        // But first event is workStarted which makes it working, then meetingStarted, then meetingEnded
        XCTAssertTrue(kinds.contains(.working))
        XCTAssertTrue(kinds.contains(.inMeeting))
    }

    // MARK: - Duration By Kind

    func testDurationByKind_emptyTimeline_returnsEmptyDict() {
        let store = makeStore()
        XCTAssertTrue(store.durationByKind().isEmpty)
    }
}
