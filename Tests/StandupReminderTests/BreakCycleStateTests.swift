import XCTest
@testable import StandupReminderLib

final class BreakCycleStateTests: XCTestCase {

    // MARK: - Initial State

    func testInitialState_allDefaults() {
        let state = BreakCycleState()
        XCTAssertEqual(state.snoozesUsed, 0)
        XCTAssertFalse(state.warningShown)
        XCTAssertFalse(state.postureNudgeShown)
    }

    // MARK: - canSnooze

    func testCanSnooze_initiallyTrue() {
        let state = BreakCycleState()
        XCTAssertTrue(state.canSnooze)
    }

    func testCanSnooze_afterOneSnooze_stillTrue() {
        var state = BreakCycleState()
        state.snoozesUsed = 1
        XCTAssertTrue(state.canSnooze)
    }

    func testCanSnooze_afterMaxSnoozes_false() {
        var state = BreakCycleState()
        state.snoozesUsed = BreakCycleState.maxSnoozes
        XCTAssertFalse(state.canSnooze)
    }

    func testCanSnooze_overMax_false() {
        var state = BreakCycleState()
        state.snoozesUsed = BreakCycleState.maxSnoozes + 1
        XCTAssertFalse(state.canSnooze)
    }

    // MARK: - nextSnoozeDuration

    func testNextSnoozeDuration_firstSnooze_5minutes() {
        let state = BreakCycleState()
        XCTAssertEqual(state.nextSnoozeDuration, 5 * 60)
    }

    func testNextSnoozeDuration_secondSnooze_2minutes() {
        var state = BreakCycleState()
        state.snoozesUsed = 1
        XCTAssertEqual(state.nextSnoozeDuration, 2 * 60)
    }

    func testNextSnoozeDuration_whenMaxedOut_returnsZero() {
        var state = BreakCycleState()
        state.snoozesUsed = BreakCycleState.maxSnoozes
        XCTAssertEqual(state.nextSnoozeDuration, 0)
    }

    // MARK: - nextSnoozeLabel

    func testNextSnoozeLabel_firstSnooze() {
        let state = BreakCycleState()
        XCTAssertEqual(state.nextSnoozeLabel, "5m")
    }

    func testNextSnoozeLabel_secondSnooze() {
        var state = BreakCycleState()
        state.snoozesUsed = 1
        XCTAssertEqual(state.nextSnoozeLabel, "2m")
    }

    func testNextSnoozeLabel_whenMaxedOut_emptyString() {
        var state = BreakCycleState()
        state.snoozesUsed = BreakCycleState.maxSnoozes
        XCTAssertEqual(state.nextSnoozeLabel, "")
    }

    // MARK: - reset

    func testReset_clearsAllFields() {
        var state = BreakCycleState()
        state.snoozesUsed = 2
        state.warningShown = true
        state.postureNudgeShown = true

        state.reset()

        XCTAssertEqual(state.snoozesUsed, 0)
        XCTAssertFalse(state.warningShown)
        XCTAssertFalse(state.postureNudgeShown)
    }

    func testReset_restoresCanSnooze() {
        var state = BreakCycleState()
        state.snoozesUsed = BreakCycleState.maxSnoozes
        XCTAssertFalse(state.canSnooze)

        state.reset()
        XCTAssertTrue(state.canSnooze)
    }

    // MARK: - Constants

    func testMaxSnoozes_isTwo() {
        XCTAssertEqual(BreakCycleState.maxSnoozes, 2)
    }

    func testSnoozeDurations_matchExpected() {
        XCTAssertEqual(BreakCycleState.snoozeDurations, [300, 120])
    }
}
