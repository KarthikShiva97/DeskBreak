import XCTest
@testable import StandupReminderLib

final class ReminderManagerTests: XCTestCase {
    var sut: ReminderManager!

    override func setUp() {
        super.setUp()
        sut = ReminderManager()
        sut.resetSession()
        // Set known configuration for deterministic tests
        sut.reminderIntervalMinutes = 25
        sut.stretchDurationSeconds = 60
        sut.blockingModeEnabled = true
    }

    // MARK: - Helpers

    /// Simulate N active ticks (user working, not in meeting).
    private func tickActive(_ count: Int) {
        for _ in 0..<count {
            sut.performTick(active: true, inMeeting: false)
        }
    }

    /// Simulate N idle ticks (user away, not in meeting).
    private func tickIdle(_ count: Int) {
        for _ in 0..<count {
            sut.performTick(active: false, inMeeting: false)
        }
    }

    /// Simulate N meeting ticks (user active in meeting).
    private func tickMeeting(_ count: Int) {
        for _ in 0..<count {
            sut.performTick(active: true, inMeeting: true)
        }
    }

    /// Number of ticks to reach the reminder threshold (25 min at 5s intervals).
    private var ticksToThreshold: Int {
        Int(TimeInterval(sut.reminderIntervalMinutes) * 60 / sut.pollInterval)
    }

    // MARK: - Work Time Accumulation

    func testActiveTick_accumulatesWorkTime() {
        tickActive(1)
        XCTAssertEqual(sut.activeSecondsSinceLastReminder, sut.pollInterval)
        XCTAssertEqual(sut.totalActiveSeconds, sut.pollInterval)
    }

    func testActiveTicks_accumulateCumulatively() {
        tickActive(10)
        XCTAssertEqual(sut.activeSecondsSinceLastReminder, 10 * sut.pollInterval)
        XCTAssertEqual(sut.totalActiveSeconds, 10 * sut.pollInterval)
    }

    func testIdleTick_doesNotAccumulateWorkTime() {
        tickIdle(5)
        XCTAssertEqual(sut.activeSecondsSinceLastReminder, 0)
        XCTAssertEqual(sut.totalActiveSeconds, 0)
    }

    func testBreakInProgress_doesNotAccumulateWorkTime() {
        sut.breakDidStart()
        sut.performTick(active: true, inMeeting: false)
        XCTAssertEqual(sut.activeSecondsSinceLastReminder, 0)
        XCTAssertEqual(sut.totalActiveSeconds, 0)
    }

    func testMeetingAndActive_accumulatesWorkTime() {
        tickMeeting(1)
        XCTAssertEqual(sut.activeSecondsSinceLastReminder, sut.pollInterval)
    }

    // MARK: - Idle Detection & Auto-Reset

    func testIdleLongerThanStretchDuration_resetsWorkTimer() {
        // Accumulate some work time
        tickActive(5)
        XCTAssertGreaterThan(sut.activeSecondsSinceLastReminder, 0)

        // Go idle for longer than stretch duration (60s / 5s = 12 ticks)
        let idleTicksNeeded = Int(ceil(TimeInterval(sut.stretchDurationSeconds) / sut.pollInterval))
        tickIdle(idleTicksNeeded)

        XCTAssertEqual(sut.activeSecondsSinceLastReminder, 0)
    }

    func testIdleShorterThanStretchDuration_doesNotReset() {
        tickActive(5)
        let workTime = sut.activeSecondsSinceLastReminder

        // Go idle for less than stretch duration
        let idleTicksNeeded = Int(ceil(TimeInterval(sut.stretchDurationSeconds) / sut.pollInterval))
        tickIdle(idleTicksNeeded - 2)

        XCTAssertEqual(sut.activeSecondsSinceLastReminder, workTime)
    }

    func testIdleReset_dismissesWarning() {
        var warningDismissed = false
        sut.onDismissWarning = { warningDismissed = true }

        tickActive(5)
        let idleTicksNeeded = Int(ceil(TimeInterval(sut.stretchDurationSeconds) / sut.pollInterval))
        tickIdle(idleTicksNeeded)

        // onDismissWarning is dispatched async on main
        let exp = expectation(description: "dismiss warning")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertTrue(warningDismissed)
    }

    func testActiveAfterIdle_clearsIdleAccumulation() {
        // Go idle for a bit (but not enough to trigger reset)
        tickIdle(3)
        // Go active again
        tickActive(1)
        // Go idle again — idle counter should restart from 0
        tickActive(5)  // accumulate some work time
        let workTime = sut.activeSecondsSinceLastReminder

        // Need full stretch duration of idle from fresh start
        tickIdle(5)  // not enough to reset
        XCTAssertEqual(sut.activeSecondsSinceLastReminder, workTime)
    }

    // MARK: - Meeting State & Break Deferral

    func testMeetingDeferral_breakNotFiredDuringMeeting() {
        var breakFired = false
        sut.onStretchBreak = { _ in breakFired = true }

        // Accumulate to just before threshold
        tickActive(ticksToThreshold - 1)

        // Cross threshold during meeting
        tickMeeting(2)

        let exp = expectation(description: "check break")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertFalse(breakFired, "Break should be deferred during meeting")
        XCTAssertGreaterThanOrEqual(sut.activeSecondsSinceLastReminder,
                                     TimeInterval(sut.reminderIntervalMinutes) * 60)
    }

    func testMeetingEnd_breakFiresImmediately() {
        var breakFired = false
        sut.onStretchBreak = { _ in breakFired = true }

        // Accumulate past threshold during meeting
        tickActive(ticksToThreshold - 1)
        tickMeeting(2)  // cross threshold in meeting

        // End meeting — next active tick should fire
        tickActive(1)

        let exp = expectation(description: "break fires")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertTrue(breakFired, "Break should fire once meeting ends")
    }

    func testMeetingCountsAsSitting() {
        tickMeeting(10)
        XCTAssertEqual(sut.continuousSittingSeconds, 10 * sut.pollInterval)
    }

    func testIdleDuringMeeting_stillCountsAsSitting() {
        // Even if HID says idle, if in meeting, sitting time accumulates
        for _ in 0..<10 {
            sut.performTick(active: false, inMeeting: true)
        }
        XCTAssertEqual(sut.continuousSittingSeconds, 10 * sut.pollInterval)
    }

    // MARK: - Posture Nudge

    func testPostureNudge_firesAtHalfway() {
        var nudgeFired = false
        sut.onPostureNudge = { nudgeFired = true }

        // Halfway = threshold / 2 = 750s = 150 ticks
        let halfwayTicks = ticksToThreshold / 2
        tickActive(halfwayTicks + 1)

        let exp = expectation(description: "nudge")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertTrue(nudgeFired)
    }

    func testPostureNudge_suppressedDuringMeeting() {
        var nudgeFired = false
        sut.onPostureNudge = { nudgeFired = true }

        let halfwayTicks = ticksToThreshold / 2
        tickMeeting(halfwayTicks + 1)

        let exp = expectation(description: "check nudge")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertFalse(nudgeFired, "Posture nudge should be suppressed during meetings")
    }

    func testPostureNudge_suppressedWhenIdle() {
        var nudgeFired = false
        sut.onPostureNudge = { nudgeFired = true }

        // Accumulate active time, then go idle at the halfway point
        tickActive(ticksToThreshold / 2 - 1)
        tickIdle(1)  // idle tick at halfway shouldn't fire nudge

        let exp = expectation(description: "check nudge")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertFalse(nudgeFired)
    }

    func testPostureNudge_onlyFiresOnce() {
        var nudgeCount = 0
        sut.onPostureNudge = { nudgeCount += 1 }

        let halfwayTicks = ticksToThreshold / 2
        tickActive(halfwayTicks + 5)  // several ticks past halfway

        let exp = expectation(description: "count nudges")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertEqual(nudgeCount, 1)
    }

    // MARK: - Warning Banner

    func testWarningBanner_firesBeforeBreak() {
        var warningFired = false
        sut.onWarning = { _, _ in warningFired = true }

        // Warning zone starts at warningLeadTimeSeconds (30s = 6 ticks) before threshold
        let warningTicks = ticksToThreshold - Int(sut.warningLeadTimeSeconds / sut.pollInterval)
        tickActive(warningTicks + 1)

        let exp = expectation(description: "warning")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertTrue(warningFired)
    }

    func testWarningBanner_suppressedDuringMeeting() {
        var warningFired = false
        sut.onWarning = { _, _ in warningFired = true }

        let warningTicks = ticksToThreshold - Int(sut.warningLeadTimeSeconds / sut.pollInterval)
        // Get near the warning zone with active ticks, then switch to meeting
        tickActive(warningTicks - 1)
        tickMeeting(2)

        let exp = expectation(description: "check warning")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertFalse(warningFired, "Warning should be suppressed during meetings")
    }

    func testWarningBanner_onlyFiresOnce() {
        var warningCount = 0
        sut.onWarning = { _, _ in warningCount += 1 }

        let warningTicks = ticksToThreshold - Int(sut.warningLeadTimeSeconds / sut.pollInterval)
        tickActive(warningTicks + 3)

        let exp = expectation(description: "count warnings")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertEqual(warningCount, 1)
    }

    func testWarningBanner_requiresBlockingMode() {
        sut.blockingModeEnabled = false
        var warningFired = false
        sut.onWarning = { _, _ in warningFired = true }

        let warningTicks = ticksToThreshold - Int(sut.warningLeadTimeSeconds / sut.pollInterval)
        tickActive(warningTicks + 1)

        let exp = expectation(description: "check warning")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertFalse(warningFired, "Warning requires blocking mode")
    }

    // MARK: - Health Warnings

    func testFirmHealthWarning_at60Minutes() {
        var healthWarnings: [(Int, Bool)] = []
        sut.onHealthWarning = { minutes, isUrgent in
            healthWarnings.append((minutes, isUrgent))
        }

        let firmTicks = Int(SittingTracker.firmThreshold / sut.pollInterval)
        tickActive(firmTicks)

        let exp = expectation(description: "firm warning")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertEqual(healthWarnings.count, 1)
        XCTAssertEqual(healthWarnings[0].0, 60)
        XCTAssertFalse(healthWarnings[0].1, "Should be non-urgent (firm)")
    }

    func testUrgentHealthWarning_at90Minutes() {
        var healthWarnings: [(Int, Bool)] = []
        sut.onHealthWarning = { minutes, isUrgent in
            healthWarnings.append((minutes, isUrgent))
        }

        // Must cross the break threshold without actually firing the break.
        // Keep using active ticks — the break will fire at 25 min and reset activeSeconds,
        // but sitting continues. So we can just keep ticking.
        let urgentTicks = Int(SittingTracker.urgentThreshold / sut.pollInterval)
        tickActive(urgentTicks)

        let exp = expectation(description: "urgent warning")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        // Should have received firm warning (at 60 min) and urgent warning (at 90 min)
        let urgentWarnings = healthWarnings.filter { $0.1 }
        XCTAssertFalse(urgentWarnings.isEmpty, "Should have received at least one urgent warning")
    }

    func testHealthWarnings_suppressedDuringMeeting() {
        var healthWarnings: [(Int, Bool)] = []
        sut.onHealthWarning = { minutes, isUrgent in
            healthWarnings.append((minutes, isUrgent))
        }

        // Accumulate sitting time during meeting (counts as sitting but
        // health warnings are suppressed during meetings)
        let firmTicks = Int(SittingTracker.firmThreshold / sut.pollInterval)
        tickMeeting(firmTicks)

        let exp = expectation(description: "check suppression")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertTrue(healthWarnings.isEmpty, "Health warnings should be suppressed during meetings")
    }

    func testHealthWarnings_resetAfterCompletedBreak() {
        // Build up sitting time past firm threshold
        let firmTicks = Int(SittingTracker.firmThreshold / sut.pollInterval)
        tickActive(firmTicks)

        // Complete a break
        sut.breakDidStart()
        sut.breakDidEnd(completed: true)

        XCTAssertEqual(sut.continuousSittingSeconds, 0, "Sitting should reset after completed break")
        XCTAssertFalse(sut.isUrgentSittingWarning)
    }

    func testHealthWarnings_notResetAfterSkippedBreak() {
        // Build up sitting time
        tickActive(20)
        let sittingBefore = sut.continuousSittingSeconds
        XCTAssertGreaterThan(sittingBefore, 0)

        // Skip a break
        sut.breakDidStart()
        sut.breakDidEnd(completed: false)

        // Sitting should NOT reset
        XCTAssertEqual(sut.continuousSittingSeconds, sittingBefore)
    }

    func testIsUrgentSittingWarning_reflectsState() {
        XCTAssertFalse(sut.isUrgentSittingWarning)

        let urgentTicks = Int(SittingTracker.urgentThreshold / sut.pollInterval)
        tickActive(urgentTicks)

        XCTAssertTrue(sut.isUrgentSittingWarning)
    }

    // MARK: - Break Firing

    func testBreakFires_atThreshold() {
        var breakFired = false
        sut.onStretchBreak = { _ in breakFired = true }

        tickActive(ticksToThreshold)

        let exp = expectation(description: "break fires")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertTrue(breakFired)
    }

    func testBreakFires_resetsWorkTimer() {
        // The break fires via fireReminder which resets timer in checkBreakThreshold
        tickActive(ticksToThreshold)

        // activeSecondsSinceLastReminder should be reset to 0
        XCTAssertEqual(sut.activeSecondsSinceLastReminder, 0)
    }

    func testBreakFires_preservesTotalActive() {
        tickActive(ticksToThreshold)
        // Total should still reflect all time worked
        XCTAssertGreaterThanOrEqual(sut.totalActiveSeconds,
                                     TimeInterval(sut.reminderIntervalMinutes) * 60)
    }

    // MARK: - Snooze

    func testSnooze_firstSnooze_subtractsFromActiveTime() {
        tickActive(50)  // 250 seconds
        let before = sut.activeSecondsSinceLastReminder
        sut.snooze()  // subtracts 300s (5 min) — capped at 0
        XCTAssertEqual(sut.activeSecondsSinceLastReminder, max(0, before - 300))
    }

    func testSnooze_secondSnooze_subtractsLess() {
        tickActive(100)  // 500 seconds
        sut.snooze()  // first snooze: -300s
        let afterFirst = sut.activeSecondsSinceLastReminder
        sut.snooze()  // second snooze: -120s
        XCTAssertEqual(sut.activeSecondsSinceLastReminder, max(0, afterFirst - 120))
    }

    func testSnooze_maxTwo() {
        tickActive(100)
        sut.snooze()
        sut.snooze()
        XCTAssertFalse(sut.canSnooze)

        let before = sut.activeSecondsSinceLastReminder
        sut.snooze()  // should be no-op
        XCTAssertEqual(sut.activeSecondsSinceLastReminder, before)
    }

    func testSnooze_clearsWarningShown() {
        // Get into warning zone
        let warningTicks = ticksToThreshold - Int(sut.warningLeadTimeSeconds / sut.pollInterval)
        tickActive(warningTicks + 1)

        // Snooze should allow warning to re-show
        sut.snooze()

        var warningFiredAgain = false
        sut.onWarning = { _, _ in warningFiredAgain = true }

        // Tick again in warning zone after snooze pushed time back
        // Need to accumulate back to warning zone
        let snoozeMinutes = 5  // first snooze is 5 min
        let ticksToReachWarning = Int(TimeInterval(snoozeMinutes * 60 - Int(sut.warningLeadTimeSeconds)) / sut.pollInterval)
        tickActive(ticksToReachWarning + 1)

        let exp = expectation(description: "re-warning")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertTrue(warningFiredAgain, "Warning should fire again after snooze")
    }

    func testSnooze_dismissesWarning() {
        var dismissed = false
        sut.onDismissWarning = { dismissed = true }

        tickActive(50)
        sut.snooze()

        let exp = expectation(description: "dismiss")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertTrue(dismissed)
    }

    // MARK: - Disable / Resume Lifecycle

    func testDisableFor_setsDisabledUntil() {
        sut.disableFor(minutes: 15)
        XCTAssertNotNil(sut.disabledUntil)
        XCTAssertTrue(sut.isDisabled)
    }

    func testDisableFor_recordsTimeline() {
        let countBefore = sut.timeline.count(of: .disabled)
        sut.disableFor(minutes: 15)
        XCTAssertEqual(sut.timeline.count(of: .disabled), countBefore + 1)
    }

    func testDisableFor_callsCallback() {
        var callbackCalled = false
        sut.onDisableStateChanged = { disabled, _ in
            callbackCalled = disabled
        }
        sut.disableFor(minutes: 15)
        XCTAssertTrue(callbackCalled)
    }

    func testDisableIndefinitely_setsDistantFuture() {
        sut.disableIndefinitely()
        XCTAssertEqual(sut.disabledUntil, .distantFuture)
        XCTAssertTrue(sut.isDisabled)
    }

    func testResumeFromDisable_clearsDisabledUntil() {
        sut.disableIndefinitely()
        sut.resumeFromDisable()
        XCTAssertNil(sut.disabledUntil)
        XCTAssertFalse(sut.isDisabled)
    }

    func testResumeFromDisable_resetsAllState() {
        // Accumulate some state
        tickActive(10)
        sut.disableIndefinitely()
        sut.resumeFromDisable()

        XCTAssertEqual(sut.activeSecondsSinceLastReminder, 0)
        XCTAssertEqual(sut.continuousSittingSeconds, 0)
        XCTAssertTrue(sut.canSnooze)
    }

    func testResumeFromDisable_recordsTimeline() {
        sut.disableIndefinitely()
        let countBefore = sut.timeline.count(of: .resumed)
        sut.resumeFromDisable()
        XCTAssertEqual(sut.timeline.count(of: .resumed), countBefore + 1)
    }

    func testIsDisabled_falseByDefault() {
        XCTAssertFalse(sut.isDisabled)
    }

    // MARK: - Break Lifecycle

    func testBreakDidStart_setsBreakInProgress() {
        XCTAssertFalse(sut.breakInProgress)
        sut.breakDidStart()
        XCTAssertTrue(sut.breakInProgress)
    }

    func testBreakDidEnd_clearsBreakInProgress() {
        sut.breakDidStart()
        sut.breakDidEnd(completed: true)
        XCTAssertFalse(sut.breakInProgress)
    }

    func testBreakDidEnd_completed_resetsSitting() {
        tickActive(10)
        XCTAssertGreaterThan(sut.continuousSittingSeconds, 0)

        sut.breakDidStart()
        sut.breakDidEnd(completed: true)
        XCTAssertEqual(sut.continuousSittingSeconds, 0)
    }

    func testBreakDidEnd_skipped_doesNotResetSitting() {
        tickActive(10)
        let sitting = sut.continuousSittingSeconds

        sut.breakDidStart()
        sut.breakDidEnd(completed: false)
        XCTAssertEqual(sut.continuousSittingSeconds, sitting)
    }

    func testBreakDidEnd_completed_recordsBreakCompleted() {
        let count = sut.timeline.count(of: .breakCompleted)
        sut.breakDidStart()
        sut.breakDidEnd(completed: true)
        XCTAssertEqual(sut.timeline.count(of: .breakCompleted), count + 1)
    }

    func testBreakDidEnd_skipped_recordsBreakSkipped() {
        let count = sut.timeline.count(of: .breakSkipped)
        sut.breakDidStart()
        sut.breakDidEnd(completed: false)
        XCTAssertEqual(sut.timeline.count(of: .breakSkipped), count + 1)
    }

    // MARK: - Trigger Break Now

    func testTriggerBreakNow_resetsWorkTimer() {
        tickActive(10)
        sut.triggerBreakNow()
        XCTAssertEqual(sut.activeSecondsSinceLastReminder, 0)
    }

    func testTriggerBreakNow_firesCallback() {
        var breakFired = false
        sut.onStretchBreak = { _ in breakFired = true }

        sut.triggerBreakNow()

        let exp = expectation(description: "break now callback")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertTrue(breakFired)
    }

    func testTriggerBreakNow_resetsSnoozes() {
        tickActive(50)
        sut.snooze()  // use first snooze
        XCTAssertFalse(sut.canSnooze == false)  // still can snooze once more

        sut.triggerBreakNow()
        XCTAssertTrue(sut.canSnooze, "Snooze count should reset after triggerBreakNow")
    }

    // MARK: - Session Reset

    func testResetSession_clearsAllCounters() {
        tickActive(20)
        sut.snooze()
        sut.breakDidStart()

        sut.resetSession()

        XCTAssertEqual(sut.activeSecondsSinceLastReminder, 0)
        XCTAssertEqual(sut.totalActiveSeconds, 0)
        XCTAssertEqual(sut.continuousSittingSeconds, 0)
        XCTAssertFalse(sut.breakInProgress)
        XCTAssertTrue(sut.canSnooze)
        XCTAssertFalse(sut.isUrgentSittingWarning)
    }

    func testResetSession_recordsTimeline() {
        let count = sut.timeline.count(of: .sessionReset)
        sut.resetSession()
        // resetSession records sessionReset; our setUp also calls resetSession
        XCTAssertGreaterThanOrEqual(sut.timeline.count(of: .sessionReset), count + 1)
    }

    // MARK: - Adaptive Break Duration

    func testAdaptiveBreakDuration_initialValue() {
        XCTAssertEqual(sut.adaptiveBreakDuration, sut.stretchDurationSeconds)
    }

    func testAdaptiveBreakDuration_cappedAt120() {
        // Force many break cycles by triggering breaks
        for _ in 0..<10 {
            tickActive(ticksToThreshold)
        }
        XCTAssertLessThanOrEqual(sut.adaptiveBreakDuration, max(sut.stretchDurationSeconds, 120))
    }

    // MARK: - Timeline Transitions

    func testTransition_idleToActive_recordsWorkStarted() {
        let count = sut.timeline.count(of: .workStarted)
        // First tick idle, then active
        tickIdle(1)
        tickActive(1)
        XCTAssertEqual(sut.timeline.count(of: .workStarted), count + 1)
    }

    func testTransition_activeToIdle_recordsWorkEnded() {
        tickActive(1)
        let count = sut.timeline.count(of: .workEnded)
        tickIdle(1)
        XCTAssertEqual(sut.timeline.count(of: .workEnded), count + 1)
    }

    func testTransition_meetingStart_recordsMeetingStarted() {
        let count = sut.timeline.count(of: .meetingStarted)
        sut.performTick(active: true, inMeeting: true)
        XCTAssertEqual(sut.timeline.count(of: .meetingStarted), count + 1)
    }

    func testTransition_meetingEnd_recordsMeetingEnded() {
        sut.performTick(active: true, inMeeting: true)
        let count = sut.timeline.count(of: .meetingEnded)
        sut.performTick(active: true, inMeeting: false)
        XCTAssertEqual(sut.timeline.count(of: .meetingEnded), count + 1)
    }

    func testTransition_workSuppressedDuringMeeting() {
        // Enter meeting
        sut.performTick(active: true, inMeeting: true)
        let workStartedCount = sut.timeline.count(of: .workStarted)
        let workEndedCount = sut.timeline.count(of: .workEnded)

        // Active → idle transitions during meeting should NOT produce work events
        sut.performTick(active: false, inMeeting: true)
        sut.performTick(active: true, inMeeting: true)

        XCTAssertEqual(sut.timeline.count(of: .workStarted), workStartedCount)
        XCTAssertEqual(sut.timeline.count(of: .workEnded), workEndedCount)
    }

    func testTransition_workSuppressedDuringBreak() {
        sut.breakDidStart()
        let count = sut.timeline.count(of: .workStarted)

        sut.performTick(active: false, inMeeting: false)
        sut.performTick(active: true, inMeeting: false)

        XCTAssertEqual(sut.timeline.count(of: .workStarted), count,
                       "Work transitions should be suppressed during break")
    }

    // MARK: - Sitting Timer Behavior

    func testSittingResets_whenIdleOutsideMeeting() {
        tickActive(10)
        XCTAssertGreaterThan(sut.continuousSittingSeconds, 0)

        tickIdle(1)
        XCTAssertEqual(sut.continuousSittingSeconds, 0,
                       "Sitting should reset when user goes idle outside meeting")
    }

    func testSittingContinues_duringMeeting() {
        tickActive(5)
        let sitting = sut.continuousSittingSeconds

        tickMeeting(5)
        XCTAssertGreaterThan(sut.continuousSittingSeconds, sitting)
    }

    func testSittingDoesNotAccumulate_duringBreak() {
        tickActive(5)
        let sitting = sut.continuousSittingSeconds

        sut.breakDidStart()
        sut.performTick(active: true, inMeeting: false)

        XCTAssertEqual(sut.continuousSittingSeconds, sitting,
                       "Sitting should not accumulate during break")
    }

    // MARK: - onTick Callback

    func testOnTick_firesEveryTick() {
        var tickCount = 0
        sut.onTick = { _, _, _, _ in tickCount += 1 }

        tickActive(5)
        XCTAssertEqual(tickCount, 5)
    }

    func testOnTick_reportsCorrectValues() {
        var lastTotal: TimeInterval = 0
        var lastActive = false
        var lastInMeeting = false

        sut.onTick = { total, _, isActive, inMeeting in
            lastTotal = total
            lastActive = isActive
            lastInMeeting = inMeeting
        }

        tickActive(3)
        XCTAssertEqual(lastTotal, 3 * sut.pollInterval)
        XCTAssertTrue(lastActive)
        XCTAssertFalse(lastInMeeting)

        tickMeeting(1)
        XCTAssertTrue(lastActive)
        XCTAssertTrue(lastInMeeting)
    }
}
