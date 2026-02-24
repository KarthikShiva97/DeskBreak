import Cocoa
import CoreAudio
import Foundation
import UserNotifications

/// Tracks cumulative work time and fires standup reminder notifications.
///
/// ## State Architecture
///
/// The reminder system's state is organized into three layers:
///
/// 1. **Operating mode** — determined by `breakInProgress` and `disabledUntil`:
///    - *Tracking*: normal operation, polling for activity
///    - *On break*: stretch overlay is showing, work time paused
///    - *Disabled*: polling stopped, either timed or indefinite
///
/// 2. **Break cycle** (`breakCycle: BreakCycleState`) — tracks progress toward
///    the next break: snooze count, warning/nudge-shown flags. Resets when a
///    break fires, when idle exceeds stretch duration, or on session reset.
///
/// 3. **Sitting tracker** (`sitting: SittingTracker`) — monitors continuous
///    sitting duration and health warning state. Resets when a break is
///    completed or the user goes idle outside a meeting.
///
/// Each tick samples two inputs — `active` (HID idle time) and `inMeeting`
/// (running meeting app + active microphone) — then updates timers and
/// checks alert thresholds.
public final class ReminderManager: NSObject, UNUserNotificationCenterDelegate {
    private let activityMonitor = ActivityMonitor()
    private var pollTimer: Timer?

    /// Cumulative seconds the user has been actively working since last reminder.
    public private(set) var activeSecondsSinceLastReminder: TimeInterval = 0

    /// Total cumulative active seconds since the session started.
    public private(set) var totalActiveSeconds: TimeInterval = 0

    /// Session statistics (streaks, break counts).
    public let stats = SessionStats()

    /// How often (in minutes) to send a standup reminder. Defaults to 25 (better for disc issues).
    public var reminderIntervalMinutes: Int = 25 {
        didSet { UserDefaults.standard.set(reminderIntervalMinutes, forKey: "reminderIntervalMinutes") }
    }

    /// Idle threshold forwarded to the activity monitor.
    public var idleThresholdSeconds: TimeInterval {
        get { activityMonitor.idleThresholdSeconds }
        set {
            activityMonitor.idleThresholdSeconds = newValue
            UserDefaults.standard.set(newValue, forKey: "idleThresholdSeconds")
        }
    }

    /// When true, shows a full-screen overlay that blocks work until stretching is done.
    public var blockingModeEnabled: Bool = true {
        didSet { UserDefaults.standard.set(blockingModeEnabled, forKey: "blockingModeEnabled") }
    }

    /// How long (seconds) the blocking stretch overlay lasts. Defaults to 60.
    public var stretchDurationSeconds: Int = 60 {
        didSet { UserDefaults.standard.set(stretchDurationSeconds, forKey: "stretchDurationSeconds") }
    }

    /// Seconds of warning before the full block. Defaults to 30.
    public let warningLeadTimeSeconds: TimeInterval = 30

    // MARK: - State (see ReminderState.swift)

    /// Per-break-cycle state: snooze count, warning/nudge flags.
    private var breakCycle = BreakCycleState()

    /// Continuous sitting duration and health warning flags.
    private var sitting = SittingTracker()

    /// Number of break cycles completed today (used for adaptive break duration).
    var breakCyclesToday: Int = 0

    /// Timer that re-enables tracking after a timed disable.
    private var resumeTimer: Timer?

    /// When the timed disable expires (nil = not disabled).
    public private(set) var disabledUntil: Date?

    /// Whether notification permission has already been requested this session.
    private var notificationPermissionRequested = false

    /// Whether a stretch break is currently in progress (don't count as work time).
    public private(set) var breakInProgress = false

    // MARK: - Daily Timeline

    /// Today's timeline event log, persisted to disk.
    /// Replaced automatically at midnight — see `rolloverDayIfNeeded()`.
    public private(set) var timeline = DailyTimelineStore()

    /// The date string (yyyy-MM-dd) the current session belongs to.
    /// Compared each tick to detect midnight crossings.
    private var currentDayString: String = DailyTimelineStore.todayString()

    /// Previous tick's active state — used to detect idle/active transitions.
    private var wasActive = false

    /// Previous tick's meeting state — used to detect meeting start/end transitions.
    private var wasInMeeting = false

    // MARK: - Continuous Idle Tracker

    /// Continuous seconds the user has been detected as idle (no input).
    /// When this exceeds the stretch duration the idle period counts as
    /// an equivalent rest and the work timer resets automatically.
    private var continuousIdleSeconds: TimeInterval = 0

    // MARK: - Forwarding Properties

    /// Whether the user is in the urgent continuous sitting state (90+ min without a completed break).
    public var isUrgentSittingWarning: Bool { sitting.isUrgent }

    /// Continuous seconds the user has been sitting without completing a break.
    public var continuousSittingSeconds: TimeInterval { sitting.continuousSeconds }

    public var canSnooze: Bool { breakCycle.canSnooze }

    /// Human-readable description of the next snooze duration.
    public var nextSnoozeLabel: String { breakCycle.nextSnoozeLabel }

    // MARK: - Callbacks

    /// Callback when timed disable starts/ends so the UI can update.
    public var onDisableStateChanged: ((_ disabled: Bool, _ until: Date?) -> Void)?

    /// Callback fired every poll tick so the UI can update the displayed time.
    public var onTick: ((_ totalActive: TimeInterval, _ sinceLast: TimeInterval, _ isActive: Bool, _ inMeeting: Bool) -> Void)?

    /// Callback fired when a blocking stretch break should be shown.
    public var onStretchBreak: ((_ durationSeconds: Int) -> Void)?

    /// Callback fired when a warning banner should appear before the break.
    public var onWarning: ((_ secondsUntilBreak: Int, _ canSnooze: Bool) -> Void)?

    /// Callback to dismiss the warning banner.
    public var onDismissWarning: (() -> Void)?

    /// Callback for a subtle posture nudge at the halfway point.
    public var onPostureNudge: (() -> Void)?

    /// Callback fired when continuous sitting exceeds health warning thresholds.
    public var onHealthWarning: ((_ continuousMinutes: Int, _ isUrgent: Bool) -> Void)?

    /// How often we poll for idle state (seconds).
    let pollInterval: TimeInterval = 5

    // MARK: - Init

    public override init() {
        let defaults = UserDefaults.standard
        let savedInterval = defaults.object(forKey: "reminderIntervalMinutes") as? Int ?? 25
        let savedBlocking = defaults.object(forKey: "blockingModeEnabled") as? Bool ?? true
        let savedStretchDuration = defaults.object(forKey: "stretchDurationSeconds") as? Int ?? 60

        self.reminderIntervalMinutes = savedInterval
        self.blockingModeEnabled = savedBlocking
        self.stretchDurationSeconds = savedStretchDuration

        super.init()

        if let savedIdle = defaults.object(forKey: "idleThresholdSeconds") as? Double, savedIdle > 0 {
            activityMonitor.idleThresholdSeconds = savedIdle
        }

        // Restore today's session data so that an app relaunch (e.g. after
        // auto-update) doesn't reset everything to 0.
        // Prefer DailyStatsStore (canonical aggregated source); fall back to
        // the timeline for users upgrading from before DailyStatsStore existed.
        let dailyRecord = DailyStatsStore.shared.todayRecord()
        if dailyRecord.breaksCompleted > 0 || dailyRecord.totalWorkSeconds > 0 {
            stats.restoreFromDailyStats(dailyRecord)
            totalActiveSeconds = dailyRecord.totalWorkSeconds
            breakCyclesToday = dailyRecord.breaksCompleted
        } else if !timeline.events.isEmpty {
            stats.restoreFromTimeline(timeline)
            let durations = timeline.durationByKind()
            totalActiveSeconds = durations[.working, default: 0] + durations[.inMeeting, default: 0]
            breakCyclesToday = stats.breaksCompleted
            // Seed DailyStatsStore so the two stores stay in sync going forward.
            DailyStatsStore.shared.seedToday(
                breaksCompleted: stats.breaksCompleted,
                breaksSkipped: stats.breaksSkipped,
                breaksSnoozed: stats.breaksSnoozed,
                healthWarnings: stats.healthWarningsReceived,
                totalWorkSeconds: totalActiveSeconds
            )
        }
    }

    deinit {
        pollTimer?.invalidate()
        resumeTimer?.invalidate()
    }

    // MARK: - Lifecycle

    public func start() {
        if pollTimer != nil {
            stop()
        }

        if !notificationPermissionRequested {
            notificationPermissionRequested = true
            requestNotificationPermission()
        }
        UNUserNotificationCenter.current().delegate = self

        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    public func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Disable tracking for a fixed duration, then auto-resume.
    public func disableFor(minutes: Int) {
        stop()
        breakInProgress = false
        let until = Date().addingTimeInterval(TimeInterval(minutes * 60))
        disabledUntil = until
        timeline.record(.disabled, detail: "\(minutes) min")
        onDisableStateChanged?(true, until)

        resumeTimer?.invalidate()
        resumeTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: false) { [weak self] _ in
            self?.resumeFromDisable()
        }
    }

    /// Disable tracking indefinitely until manually resumed.
    public func disableIndefinitely() {
        stop()
        breakInProgress = false
        disabledUntil = .distantFuture
        resumeTimer?.invalidate()
        resumeTimer = nil
        timeline.record(.disabled, detail: "indefinite")
        onDisableStateChanged?(true, .distantFuture)
    }

    /// Resume tracking (called by auto-timer or manually).
    public func resumeFromDisable() {
        resumeTimer?.invalidate()
        resumeTimer = nil
        disabledUntil = nil
        activeSecondsSinceLastReminder = 0
        continuousIdleSeconds = 0
        breakCycle.reset()
        sitting.reset()
        breakCyclesToday = 0
        start()
        timeline.record(.resumed)
        onDisableStateChanged?(false, nil)
    }

    public var isDisabled: Bool {
        disabledUntil != nil
    }

    public func resetSession() {
        activeSecondsSinceLastReminder = 0
        totalActiveSeconds = 0
        continuousIdleSeconds = 0
        breakCycle.reset()
        sitting.reset()
        breakCyclesToday = 0
        breakInProgress = false
        stats.resetSession()
        timeline.record(.sessionReset)
    }

    /// Call when a stretch overlay appears.
    public func breakDidStart() {
        breakInProgress = true
        timeline.record(.breakStarted)
    }

    /// Call when a stretch overlay is dismissed.
    /// - Parameter completed: true if the user completed the full stretch, false if skipped.
    public func breakDidEnd(completed: Bool) {
        breakInProgress = false
        timeline.record(completed ? .breakCompleted : .breakSkipped)
        if completed {
            sitting.reset()
        }
    }

    /// Manually trigger a break right now (e.g., user feels stiffness).
    public func triggerBreakNow() {
        activeSecondsSinceLastReminder = 0
        breakCycle.reset()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onDismissWarning?()
            if self.blockingModeEnabled {
                self.breakDidStart()
                self.onStretchBreak?(self.adaptiveBreakDuration)
            }
        }
    }

    /// Snooze the current break. First snooze = 5min, second = 2min.
    public func snooze() {
        guard breakCycle.canSnooze else { return }
        let snoozeAmount = breakCycle.nextSnoozeDuration
        breakCycle.snoozesUsed += 1
        breakCycle.warningShown = false  // allow warning to re-show before next break
        stats.recordBreakSnoozed()
        timeline.record(.breakSnoozed, detail: "\(Int(snoozeAmount / 60))m")
        activeSecondsSinceLastReminder = max(0, activeSecondsSinceLastReminder - snoozeAmount)

        DispatchQueue.main.async { [weak self] in
            self?.onDismissWarning?()
        }
    }

    /// Adaptive break duration: increases by 15s per cycle, capped at 120s or
    /// the user's configured duration (whichever is larger — never reduce their setting).
    public var adaptiveBreakDuration: Int {
        let cap = max(stretchDurationSeconds, 120)
        return min(stretchDurationSeconds + breakCyclesToday * 15, cap)
    }

    // MARK: - Meeting Detection

    /// Returns true if a known video-call / screen-sharing app is running AND
    /// a microphone is actively being captured — indicating a live call.
    private func isInMeeting() -> Bool {
        let meetingBundleIDs = [
            "us.zoom.xos",               // Zoom
            "com.cisco.webexmeetingsapp", // Webex
            "com.microsoft.teams",        // Teams
            "com.apple.FaceTime",         // FaceTime
        ]
        let meetingNameFragments = [
            "Screen Sharing",             // Slack screen sharing helper
            "ScreenFlow",
            "OBS",
        ]

        var meetingAppRunning = false
        for app in NSWorkspace.shared.runningApplications {
            if let bundleID = app.bundleIdentifier,
               meetingBundleIDs.contains(where: { bundleID.hasPrefix($0) }),
               !app.isTerminated {
                meetingAppRunning = true
                break
            }
            if let name = app.localizedName,
               meetingNameFragments.contains(where: { name.contains($0) }),
               !app.isTerminated {
                meetingAppRunning = true
                break
            }
        }

        guard meetingAppRunning else { return false }

        return isAudioInputActive()
    }

    /// Returns `true` when any hardware audio-input device (microphone) is
    /// actively being captured by some process on the system.
    private func isAudioInputActive() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &dataSize
        ) == noErr, dataSize > 0 else { return false }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &dataSize, &devices
        ) == noErr else { return false }

        for device in devices {
            var inputStreamAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(
                device, &inputStreamAddr, 0, nil, &streamSize
            ) == noErr, streamSize > 0 else { continue }

            var runAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var isRunning: UInt32 = 0
            var runSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(
                device, &runAddr, 0, nil, &runSize, &isRunning
            ) == noErr else { continue }

            if isRunning != 0 {
                return true
            }
        }
        return false
    }

    // MARK: - Day Rollover

    /// Detects when the calendar day has changed (midnight crossing) and
    /// resets all per-day state so "today" stats are clean.
    /// Called every tick (~5s) so the check is lightweight (string compare).
    private func rolloverDayIfNeeded() {
        let today = DailyTimelineStore.todayString()
        guard today != currentDayString else { return }

        // Flush yesterday's stats to disk before switching.
        DailyStatsStore.shared.updateTotalWorkSeconds(totalActiveSeconds)
        DailyStatsStore.shared.flush()

        // Create a fresh timeline for the new day.
        timeline = DailyTimelineStore()
        currentDayString = today

        // Reset session counters — the new day starts from zero.
        totalActiveSeconds = 0
        activeSecondsSinceLastReminder = 0
        continuousIdleSeconds = 0
        breakCycle.reset()
        sitting.reset()
        breakCyclesToday = 0
        breakInProgress = false
        stats.resetSession()

        // Notify the UI so menu bar and stats window reflect the reset.
        onTick?(0, 0, false, false)
    }

    // MARK: - Tick

    /// Production entry point: reads real sensors then delegates to `performTick`.
    private func tick() {
        rolloverDayIfNeeded()
        performTick(active: activityMonitor.isUserActive(), inMeeting: isInMeeting())
    }

    /// Core tick logic with injectable inputs. Called by the timer with real
    /// sensor readings, and by tests with controlled values.
    func performTick(active: Bool, inMeeting: Bool) {
        recordTransitions(active: active, inMeeting: inMeeting)
        updateTimers(active: active, inMeeting: inMeeting)

        onTick?(totalActiveSeconds, activeSecondsSinceLastReminder, active, inMeeting)

        let thresholdSeconds = TimeInterval(reminderIntervalMinutes) * 60
        let timeUntilBreak = thresholdSeconds - activeSecondsSinceLastReminder

        checkPostureNudge(active: active, inMeeting: inMeeting, timeUntilBreak: timeUntilBreak, thresholdSeconds: thresholdSeconds)
        checkWarningBanner(active: active, inMeeting: inMeeting, timeUntilBreak: timeUntilBreak)
        checkHealthWarnings(inMeeting: inMeeting)
        checkBreakThreshold(active: active, inMeeting: inMeeting, thresholdSeconds: thresholdSeconds)
    }

    // MARK: - Tick: Record Transitions

    private func recordTransitions(active: Bool, inMeeting: Bool) {
        if inMeeting && !wasInMeeting {
            timeline.record(.meetingStarted)
        } else if !inMeeting && wasInMeeting {
            timeline.record(.meetingEnded)
        }

        if !inMeeting && !wasInMeeting && !breakInProgress {
            if active && !wasActive {
                timeline.record(.workStarted)
            } else if !active && wasActive {
                timeline.record(.workEnded)
            }
        }

        wasActive = active
        wasInMeeting = inMeeting
    }

    // MARK: - Tick: Update Timers

    private func updateTimers(active: Bool, inMeeting: Bool) {
        if active && !breakInProgress {
            activeSecondsSinceLastReminder += pollInterval
            totalActiveSeconds += pollInterval
        }

        if !active && !breakInProgress {
            continuousIdleSeconds += pollInterval
            if continuousIdleSeconds >= TimeInterval(stretchDurationSeconds)
                && activeSecondsSinceLastReminder > 0 {
                activeSecondsSinceLastReminder = 0
                breakCycle.reset()
                DispatchQueue.main.async { [weak self] in
                    self?.onDismissWarning?()
                }
            }
        } else {
            continuousIdleSeconds = 0
        }

        if (active || inMeeting) && !breakInProgress {
            sitting.continuousSeconds += pollInterval
            stats.updateLongestContinuousSitting(sitting.continuousSeconds)
        } else if !active && !inMeeting && sitting.continuousSeconds > 0 {
            sitting.reset()
        }
    }

    // MARK: - Tick: Posture Nudge

    private func checkPostureNudge(active: Bool, inMeeting: Bool, timeUntilBreak: TimeInterval, thresholdSeconds: TimeInterval) {
        guard !breakCycle.postureNudgeShown && active && !inMeeting
              && activeSecondsSinceLastReminder >= (thresholdSeconds / 2)
              && timeUntilBreak > warningLeadTimeSeconds else { return }

        breakCycle.postureNudgeShown = true
        DispatchQueue.main.async { [weak self] in
            self?.onPostureNudge?()
        }
    }

    // MARK: - Tick: Warning Banner

    private func checkWarningBanner(active: Bool, inMeeting: Bool, timeUntilBreak: TimeInterval) {
        guard blockingModeEnabled && !breakCycle.warningShown && active && !inMeeting
              && timeUntilBreak <= warningLeadTimeSeconds && timeUntilBreak > 0 else { return }

        breakCycle.warningShown = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onWarning?(Int(timeUntilBreak), self.breakCycle.canSnooze)
        }
    }

    // MARK: - Tick: Health Warnings

    private func checkHealthWarnings(inMeeting: Bool) {
        guard !inMeeting && !breakInProgress else { return }

        if sitting.continuousSeconds >= SittingTracker.urgentThreshold {
            if !sitting.urgentWarningShown {
                sitting.urgentWarningShown = true
                sitting.lastUrgentWarningAt = sitting.continuousSeconds
                emitHealthWarning(isUrgent: true)
            } else if sitting.continuousSeconds - sitting.lastUrgentWarningAt >= SittingTracker.urgentRepeatInterval {
                sitting.lastUrgentWarningAt = sitting.continuousSeconds
                emitHealthWarning(isUrgent: true)
            }
        } else if sitting.continuousSeconds >= SittingTracker.firmThreshold && !sitting.firmWarningShown {
            sitting.firmWarningShown = true
            emitHealthWarning(isUrgent: false)
        }
    }

    private func emitHealthWarning(isUrgent: Bool) {
        let minutes = sitting.continuousMinutes
        stats.recordHealthWarning()
        timeline.record(.healthWarning, detail: "\(minutes) min\(isUrgent ? " (urgent)" : "")")
        DispatchQueue.main.async { [weak self] in
            self?.onHealthWarning?(minutes, isUrgent)
        }
    }

    // MARK: - Tick: Break Threshold

    private func checkBreakThreshold(active: Bool, inMeeting: Bool, thresholdSeconds: TimeInterval) {
        guard active && activeSecondsSinceLastReminder >= thresholdSeconds else { return }

        if inMeeting {
            return
        }

        fireReminder()
        activeSecondsSinceLastReminder = 0
        breakCycle.reset()
    }

    // MARK: - Notifications

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                print("Notification permission error: \(error.localizedDescription)")
            }
            if !granted {
                print("Notification permission denied. Reminders will only appear in the menu bar.")
            }
        }
    }

    private func fireReminder() {
        breakCyclesToday += 1
        let duration = adaptiveBreakDuration

        let content = UNMutableNotificationContent()
        content.title = "Standup Reminder"
        let minutes = Int(totalActiveSeconds) / 60
        content.body = "You've been working for \(minutes) minutes. Time to stand up and decompress your spine!"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "standup-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Failed to deliver notification: \(error.localizedDescription)")
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onDismissWarning?()
            if self.blockingModeEnabled {
                self.breakDidStart()
                self.onStretchBreak?(duration)
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
