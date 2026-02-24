import XCTest
@testable import StandupReminderLib

final class ActivityMonitorTests: XCTestCase {

    // MARK: - Idle Threshold Configuration

    func testDefaultIdleThreshold() {
        let monitor = ActivityMonitor()
        XCTAssertEqual(monitor.idleThresholdSeconds, 120,
                       "Default idle threshold should be 120 seconds (2 minutes)")
    }

    func testIdleThreshold_isConfigurable() {
        let monitor = ActivityMonitor()
        monitor.idleThresholdSeconds = 300
        XCTAssertEqual(monitor.idleThresholdSeconds, 300)
    }

    func testIdleThreshold_veryShort() {
        let monitor = ActivityMonitor()
        monitor.idleThresholdSeconds = 1
        XCTAssertEqual(monitor.idleThresholdSeconds, 1)
    }

    func testIdleThreshold_veryLong() {
        let monitor = ActivityMonitor()
        monitor.idleThresholdSeconds = 3600
        XCTAssertEqual(monitor.idleThresholdSeconds, 3600)
    }

    // MARK: - System Idle Time

    func testSystemIdleTime_returnsNonNegative() {
        let monitor = ActivityMonitor()
        let idleTime = monitor.systemIdleTime()
        XCTAssertGreaterThanOrEqual(idleTime, 0,
                                     "Idle time should never be negative")
    }

    // MARK: - isUserActive

    func testIsUserActive_consistentWithIdleTime() {
        let monitor = ActivityMonitor()
        let idle = monitor.systemIdleTime()
        let active = monitor.isUserActive()

        // If idle < threshold, user should be active; if >= threshold, inactive
        if idle < monitor.idleThresholdSeconds {
            XCTAssertTrue(active, "User should be active when idle time (\(idle)) < threshold (\(monitor.idleThresholdSeconds))")
        } else {
            XCTAssertFalse(active, "User should be inactive when idle time (\(idle)) >= threshold (\(monitor.idleThresholdSeconds))")
        }
    }
}
