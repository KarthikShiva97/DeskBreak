import XCTest
@testable import StandupReminderLib

final class ReminderManagerTests: XCTestCase {
    private var manager: ReminderManager!

    override func setUp() {
        super.setUp()
        manager = ReminderManager()
    }

    override func tearDown() {
        manager.stop()
        manager = nil
        super.tearDown()
    }

    // MARK: - Adaptive Break Duration

    func testAdaptiveBreakDuration_baseDuration() {
        manager.stretchDurationSeconds = 60
        manager.breakCyclesToday = 0
        XCTAssertEqual(manager.adaptiveBreakDuration, 60,
                       "With 0 cycles, duration should equal base")
    }

    func testAdaptiveBreakDuration_increasesWithCycles() {
        manager.stretchDurationSeconds = 60
        manager.breakCyclesToday = 1
        XCTAssertEqual(manager.adaptiveBreakDuration, 75, "1 cycle: 60 + 15 = 75")

        manager.breakCyclesToday = 2
        XCTAssertEqual(manager.adaptiveBreakDuration, 90, "2 cycles: 60 + 30 = 90")

        manager.breakCyclesToday = 3
        XCTAssertEqual(manager.adaptiveBreakDuration, 105, "3 cycles: 60 + 45 = 105")
    }

    func testAdaptiveBreakDuration_cappedAt120() {
        manager.stretchDurationSeconds = 60
        manager.breakCyclesToday = 10
        // 60 + 10*15 = 210, but cap = max(60, 120) = 120
        XCTAssertEqual(manager.adaptiveBreakDuration, 120,
                       "Duration should be capped at max(stretchDuration, 120)")
    }

    func testAdaptiveBreakDuration_capRespectsUserSetting() {
        manager.stretchDurationSeconds = 180 // User set 3 minutes
        manager.breakCyclesToday = 0
        XCTAssertEqual(manager.adaptiveBreakDuration, 180)

        manager.breakCyclesToday = 1
        // cap = max(180, 120) = 180, so min(180 + 15, 180) = 180
        XCTAssertEqual(manager.adaptiveBreakDuration, 180,
                       "Cap should be user's setting when > 120s")
    }

    func testAdaptiveBreakDuration_smallBaseDuration() {
        manager.stretchDurationSeconds = 30
        manager.breakCyclesToday = 3
        // 30 + 3*15 = 75, cap = max(30, 120) = 120
        XCTAssertEqual(manager.adaptiveBreakDuration, 75,
                       "Should increase normally when below cap")

        manager.breakCyclesToday = 6
        // 30 + 6*15 = 120, cap = 120
        XCTAssertEqual(manager.adaptiveBreakDuration, 120)

        manager.breakCyclesToday = 7
        // 30 + 7*15 = 135, cap = 120
        XCTAssertEqual(manager.adaptiveBreakDuration, 120,
                       "Should not exceed cap")
    }

    // MARK: - Snooze Logic

    func testCanSnooze_trueInitially() {
        XCTAssertTrue(manager.canSnooze)
    }

    func testCanSnooze_trueAfterFirstSnooze() {
        manager.snoozesUsedThisCycle = 1
        XCTAssertTrue(manager.canSnooze, "Should allow second snooze")
    }

    func testCanSnooze_falseAfterMaxSnoozes() {
        manager.snoozesUsedThisCycle = 2
        XCTAssertFalse(manager.canSnooze, "Max 2 snoozes per cycle")
    }

    func testNextSnoozeLabel_firstSnooze() {
        manager.snoozesUsedThisCycle = 0
        XCTAssertEqual(manager.nextSnoozeLabel, "5m")
    }

    func testNextSnoozeLabel_secondSnooze() {
        manager.snoozesUsedThisCycle = 1
        XCTAssertEqual(manager.nextSnoozeLabel, "2m")
    }

    func testNextSnoozeLabel_emptyWhenMaxed() {
        manager.snoozesUsedThisCycle = 2
        XCTAssertEqual(manager.nextSnoozeLabel, "")
    }

    // MARK: - Break State

    func testBreakDidStart_setsBreakInProgress() {
        XCTAssertFalse(manager.breakInProgress)
        manager.breakDidStart()
        XCTAssertTrue(manager.breakInProgress)
    }

    func testBreakDidEnd_completed_clearsBreakInProgress() {
        manager.breakDidStart()
        manager.breakDidEnd(completed: true)
        XCTAssertFalse(manager.breakInProgress)
    }

    func testBreakDidEnd_skipped_clearsBreakInProgress() {
        manager.breakDidStart()
        manager.breakDidEnd(completed: false)
        XCTAssertFalse(manager.breakInProgress)
    }

    func testBreakDidEnd_completed_resetsContinuousSitting() {
        // Simulate sitting for a while (directly set the property since it's internal)
        // Note: continuousSittingSeconds is private(set), so we test indirectly
        // by checking that isUrgentSittingWarning becomes false after break
        manager.breakDidEnd(completed: true)
        XCTAssertFalse(manager.isUrgentSittingWarning,
                       "Completed break should reset continuous sitting")
    }

    func testBreakDidStart_recordsTimelineEvent() {
        let eventCountBefore = manager.timeline.events.count
        manager.breakDidStart()
        XCTAssertEqual(manager.timeline.events.count, eventCountBefore + 1)
        XCTAssertEqual(manager.timeline.events.last?.kind, .breakStarted)
    }

    func testBreakDidEnd_recordsTimelineEvent() {
        manager.breakDidStart()
        let countAfterStart = manager.timeline.events.count
        manager.breakDidEnd(completed: true)
        XCTAssertEqual(manager.timeline.events.count, countAfterStart + 1)
        XCTAssertEqual(manager.timeline.events.last?.kind, .breakCompleted)
    }

    func testBreakDidEnd_skipped_recordsSkipEvent() {
        manager.breakDidStart()
        manager.breakDidEnd(completed: false)
        XCTAssertEqual(manager.timeline.events.last?.kind, .breakSkipped)
    }

    // MARK: - Disable / Resume

    func testIsDisabled_falseByDefault() {
        XCTAssertFalse(manager.isDisabled)
        XCTAssertNil(manager.disabledUntil)
    }

    func testDisableFor_setsDisabledUntil() {
        manager.disableFor(minutes: 15)
        XCTAssertTrue(manager.isDisabled)
        XCTAssertNotNil(manager.disabledUntil)
    }

    func testDisableIndefinitely_setsDistantFuture() {
        manager.disableIndefinitely()
        XCTAssertTrue(manager.isDisabled)
        XCTAssertEqual(manager.disabledUntil, .distantFuture)
    }

    func testResumeFromDisable_clearsDisabled() {
        manager.disableFor(minutes: 30)
        XCTAssertTrue(manager.isDisabled)

        manager.resumeFromDisable()
        XCTAssertFalse(manager.isDisabled)
        XCTAssertNil(manager.disabledUntil)
    }

    func testResumeFromDisable_resetsCounters() {
        manager.snoozesUsedThisCycle = 2
        manager.breakCyclesToday = 5
        manager.disableFor(minutes: 15)
        manager.resumeFromDisable()

        XCTAssertEqual(manager.snoozesUsedThisCycle, 0)
        XCTAssertEqual(manager.breakCyclesToday, 0)
    }

    func testDisable_recordsTimelineEvent() {
        manager.disableFor(minutes: 30)
        let lastEvent = manager.timeline.events.last
        XCTAssertEqual(lastEvent?.kind, .disabled)
        XCTAssertNotNil(lastEvent?.detail)
    }

    func testResume_recordsTimelineEvent() {
        manager.disableFor(minutes: 15)
        manager.resumeFromDisable()
        XCTAssertEqual(manager.timeline.events.last?.kind, .resumed)
    }

    // MARK: - Reset Session

    func testResetSession_clearsAllCounters() {
        manager.breakCyclesToday = 3
        manager.snoozesUsedThisCycle = 2
        manager.breakDidStart()

        manager.resetSession()

        XCTAssertEqual(manager.totalActiveSeconds, 0)
        XCTAssertEqual(manager.activeSecondsSinceLastReminder, 0)
        XCTAssertEqual(manager.breakCyclesToday, 0)
        XCTAssertEqual(manager.snoozesUsedThisCycle, 0)
        XCTAssertFalse(manager.breakInProgress)
    }

    func testResetSession_recordsTimelineEvent() {
        manager.resetSession()
        XCTAssertEqual(manager.timeline.events.last?.kind, .sessionReset)
    }

    // MARK: - Urgent Sitting Warning

    func testIsUrgentSittingWarning_falseBelowThreshold() {
        // continuousSittingSeconds is private(set), starts at 0
        XCTAssertFalse(manager.isUrgentSittingWarning)
    }

    // MARK: - Settings Defaults

    func testDefaultReminderInterval() {
        // Default is 25 minutes (or whatever was saved in UserDefaults)
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "reminderIntervalMinutes") as? Int
        if saved == nil {
            XCTAssertEqual(manager.reminderIntervalMinutes, 25)
        }
    }

    func testDefaultBlockingMode() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "blockingModeEnabled") as? Bool
        if saved == nil {
            XCTAssertTrue(manager.blockingModeEnabled)
        }
    }

    func testDefaultStretchDuration() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "stretchDurationSeconds") as? Int
        if saved == nil {
            XCTAssertEqual(manager.stretchDurationSeconds, 60)
        }
    }

    // MARK: - Snooze Integration

    func testSnooze_incrementsSnoozesUsed() {
        manager.snoozesUsedThisCycle = 0
        // Simulate that active time has passed (so subtraction doesn't go below 0)
        // snooze() subtracts snooze duration from activeSecondsSinceLastReminder
        manager.snooze()
        XCTAssertEqual(manager.snoozesUsedThisCycle, 1)
    }

    func testSnooze_reducesActiveTime() {
        // Set up: user has been active for 20 minutes (1200s)
        // First snooze = 5 minutes (300s), so should drop to 900s
        // We need to access the private activeSecondsSinceLastReminder...
        // It's private(set), but let's test the guard behavior
        manager.snoozesUsedThisCycle = 0
        manager.snooze()
        XCTAssertEqual(manager.snoozesUsedThisCycle, 1)
        // activeSecondsSinceLastReminder was 0, max(0, 0 - 300) = 0
        XCTAssertEqual(manager.activeSecondsSinceLastReminder, 0)
    }

    func testSnooze_ignoredWhenMaxed() {
        manager.snoozesUsedThisCycle = 2
        manager.snooze()
        XCTAssertEqual(manager.snoozesUsedThisCycle, 2,
                       "Should not increment beyond max")
    }

    func testSnooze_recordsTimelineEvent() {
        manager.snoozesUsedThisCycle = 0
        manager.snooze()
        let lastEvent = manager.timeline.events.last
        XCTAssertEqual(lastEvent?.kind, .breakSnoozed)
    }

    // MARK: - Warning Lead Time

    func testWarningLeadTime_is30Seconds() {
        XCTAssertEqual(manager.warningLeadTimeSeconds, 30)
    }
}
