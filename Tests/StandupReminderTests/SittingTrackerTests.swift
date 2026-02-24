import XCTest
@testable import StandupReminderLib

final class SittingTrackerTests: XCTestCase {

    // MARK: - Initial State

    func testInitialState_allDefaults() {
        let tracker = SittingTracker()
        XCTAssertEqual(tracker.continuousSeconds, 0)
        XCTAssertFalse(tracker.firmWarningShown)
        XCTAssertFalse(tracker.urgentWarningShown)
        XCTAssertEqual(tracker.lastUrgentWarningAt, 0)
    }

    // MARK: - isUrgent

    func testIsUrgent_belowThreshold_false() {
        var tracker = SittingTracker()
        tracker.continuousSeconds = SittingTracker.urgentThreshold - 1
        XCTAssertFalse(tracker.isUrgent)
    }

    func testIsUrgent_atThreshold_true() {
        var tracker = SittingTracker()
        tracker.continuousSeconds = SittingTracker.urgentThreshold
        XCTAssertTrue(tracker.isUrgent)
    }

    func testIsUrgent_aboveThreshold_true() {
        var tracker = SittingTracker()
        tracker.continuousSeconds = SittingTracker.urgentThreshold + 600
        XCTAssertTrue(tracker.isUrgent)
    }

    // MARK: - continuousMinutes

    func testContinuousMinutes_zeroSeconds() {
        let tracker = SittingTracker()
        XCTAssertEqual(tracker.continuousMinutes, 0)
    }

    func testContinuousMinutes_exactMinutes() {
        var tracker = SittingTracker()
        tracker.continuousSeconds = 3600  // 60 minutes
        XCTAssertEqual(tracker.continuousMinutes, 60)
    }

    func testContinuousMinutes_roundsDown() {
        var tracker = SittingTracker()
        tracker.continuousSeconds = 119  // 1 min 59 sec
        XCTAssertEqual(tracker.continuousMinutes, 1)
    }

    func testContinuousMinutes_lessThanOneMinute() {
        var tracker = SittingTracker()
        tracker.continuousSeconds = 59
        XCTAssertEqual(tracker.continuousMinutes, 0)
    }

    // MARK: - reset

    func testReset_clearsAllFields() {
        var tracker = SittingTracker()
        tracker.continuousSeconds = 5400
        tracker.firmWarningShown = true
        tracker.urgentWarningShown = true
        tracker.lastUrgentWarningAt = 5400

        tracker.reset()

        XCTAssertEqual(tracker.continuousSeconds, 0)
        XCTAssertFalse(tracker.firmWarningShown)
        XCTAssertFalse(tracker.urgentWarningShown)
        XCTAssertEqual(tracker.lastUrgentWarningAt, 0)
    }

    func testReset_afterUrgentState_noLongerUrgent() {
        var tracker = SittingTracker()
        tracker.continuousSeconds = SittingTracker.urgentThreshold
        XCTAssertTrue(tracker.isUrgent)

        tracker.reset()
        XCTAssertFalse(tracker.isUrgent)
    }

    // MARK: - Threshold Constants

    func testFirmThreshold_is60minutes() {
        XCTAssertEqual(SittingTracker.firmThreshold, 3600)
    }

    func testUrgentThreshold_is90minutes() {
        XCTAssertEqual(SittingTracker.urgentThreshold, 5400)
    }

    func testUrgentRepeatInterval_is10minutes() {
        XCTAssertEqual(SittingTracker.urgentRepeatInterval, 600)
    }
}
