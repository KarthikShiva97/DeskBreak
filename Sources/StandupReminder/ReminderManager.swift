import Cocoa
import CoreAudio
import Foundation
import UserNotifications

/// Tracks cumulative work time and fires standup reminder notifications.
final class ReminderManager: NSObject, UNUserNotificationCenterDelegate {
    private let activityMonitor = ActivityMonitor()
    private var pollTimer: Timer?

    /// Cumulative seconds the user has been actively working since last reminder.
    private(set) var activeSecondsSinceLastReminder: TimeInterval = 0

    /// Total cumulative active seconds since the session started.
    private(set) var totalActiveSeconds: TimeInterval = 0

    /// Session statistics (streaks, break counts).
    let stats = SessionStats()

    /// How often (in minutes) to send a standup reminder. Defaults to 25 (better for disc issues).
    var reminderIntervalMinutes: Int = 25 {
        didSet { UserDefaults.standard.set(reminderIntervalMinutes, forKey: "reminderIntervalMinutes") }
    }

    /// Idle threshold forwarded to the activity monitor.
    var idleThresholdSeconds: TimeInterval {
        get { activityMonitor.idleThresholdSeconds }
        set {
            activityMonitor.idleThresholdSeconds = newValue
            UserDefaults.standard.set(newValue, forKey: "idleThresholdSeconds")
        }
    }

    /// When true, shows a full-screen overlay that blocks work until stretching is done.
    var blockingModeEnabled: Bool = true {
        didSet { UserDefaults.standard.set(blockingModeEnabled, forKey: "blockingModeEnabled") }
    }

    /// How long (seconds) the blocking stretch overlay lasts. Defaults to 60.
    var stretchDurationSeconds: Int = 60 {
        didSet { UserDefaults.standard.set(stretchDurationSeconds, forKey: "stretchDurationSeconds") }
    }

    /// Seconds of warning before the full block. Defaults to 30.
    let warningLeadTimeSeconds: TimeInterval = 30

    /// Number of snoozes used this cycle. Max 2: first = 5min, second = 2min.
    private var snoozesUsedThisCycle: Int = 0
    private static let maxSnoozesPerCycle = 2
    private static let snoozeDurations: [TimeInterval] = [5 * 60, 2 * 60]

    /// Whether the warning has been shown for the current cycle.
    private var warningShownThisCycle = false

    /// Whether posture nudge has been shown for the current cycle.
    private var postureNudgeShownThisCycle = false

    /// Number of break cycles completed today (used for adaptive break duration).
    private var breakCyclesToday: Int = 0

    /// Timer that re-enables tracking after a timed disable.
    private var resumeTimer: Timer?

    /// When the timed disable expires (nil = not disabled).
    private(set) var disabledUntil: Date?

    /// Whether notification permission has already been requested this session.
    private var notificationPermissionRequested = false

    /// Whether a stretch break is currently in progress (don't count as work time).
    private(set) var breakInProgress = false

    // MARK: - Daily Timeline

    /// Today's timeline event log, persisted to disk.
    let timeline = DailyTimelineStore()

    /// Previous tick's active state — used to detect idle/active transitions.
    private var wasActive = false

    /// Previous tick's meeting state — used to detect meeting start/end transitions.
    private var wasInMeeting = false

    // MARK: - Continuous Sitting Tracker

    /// Continuous seconds the user has been sitting without completing a break.
    /// Unlike activeSecondsSinceLastReminder, this only resets when a break is
    /// actually completed or the user goes idle — not when a break is skipped.
    private(set) var continuousSittingSeconds: TimeInterval = 0

    /// Whether the firm health warning (60 min) has fired this sitting period.
    private var firmHealthWarningShown = false

    /// Whether the urgent health warning (90 min) has fired this sitting period.
    private var urgentHealthWarningShown = false

    /// Timestamp (in continuousSittingSeconds) of last urgent notification, for repeats.
    private var lastUrgentWarningAt: TimeInterval = 0

    /// Health warning thresholds.
    private static let firmWarningThreshold: TimeInterval = 60 * 60    // 60 minutes
    private static let urgentWarningThreshold: TimeInterval = 90 * 60  // 90 minutes
    private static let urgentRepeatInterval: TimeInterval = 10 * 60    // repeat every 10 min after 90

    /// Whether the user is in the urgent continuous sitting state (90+ min without a completed break).
    var isUrgentSittingWarning: Bool {
        continuousSittingSeconds >= Self.urgentWarningThreshold
    }

    // MARK: - Callbacks

    /// Callback when timed disable starts/ends so the UI can update.
    var onDisableStateChanged: ((_ disabled: Bool, _ until: Date?) -> Void)?

    /// Callback fired every poll tick so the UI can update the displayed time.
    var onTick: ((_ totalActive: TimeInterval, _ sinceLast: TimeInterval, _ isActive: Bool, _ inMeeting: Bool) -> Void)?

    /// Callback fired when a blocking stretch break should be shown.
    var onStretchBreak: ((_ durationSeconds: Int) -> Void)?

    /// Callback fired when a warning banner should appear before the break.
    var onWarning: ((_ secondsUntilBreak: Int, _ canSnooze: Bool) -> Void)?

    /// Callback to dismiss the warning banner.
    var onDismissWarning: (() -> Void)?

    /// Callback for a subtle posture nudge at the halfway point.
    var onPostureNudge: (() -> Void)?

    /// Callback fired when continuous sitting exceeds health warning thresholds.
    var onHealthWarning: ((_ continuousMinutes: Int, _ isUrgent: Bool) -> Void)?

    /// How often we poll for idle state (seconds).
    private let pollInterval: TimeInterval = 5

    // MARK: - Init

    override init() {
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
    }

    deinit {
        pollTimer?.invalidate()
        resumeTimer?.invalidate()
    }

    // MARK: - Lifecycle

    func start() {
        // Guard against creating duplicate timers
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

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Disable tracking for a fixed duration, then auto-resume.
    func disableFor(minutes: Int) {
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
    func disableIndefinitely() {
        stop()
        breakInProgress = false
        disabledUntil = .distantFuture
        resumeTimer?.invalidate()
        resumeTimer = nil
        timeline.record(.disabled, detail: "indefinite")
        onDisableStateChanged?(true, .distantFuture)
    }

    /// Resume tracking (called by auto-timer or manually).
    func resumeFromDisable() {
        resumeTimer?.invalidate()
        resumeTimer = nil
        disabledUntil = nil
        activeSecondsSinceLastReminder = 0
        continuousSittingSeconds = 0
        snoozesUsedThisCycle = 0
        warningShownThisCycle = false
        postureNudgeShownThisCycle = false
        firmHealthWarningShown = false
        urgentHealthWarningShown = false
        lastUrgentWarningAt = 0
        breakCyclesToday = 0
        start()
        timeline.record(.resumed)
        onDisableStateChanged?(false, nil)
    }

    var isDisabled: Bool {
        disabledUntil != nil
    }

    func resetSession() {
        activeSecondsSinceLastReminder = 0
        totalActiveSeconds = 0
        continuousSittingSeconds = 0
        snoozesUsedThisCycle = 0
        warningShownThisCycle = false
        postureNudgeShownThisCycle = false
        firmHealthWarningShown = false
        urgentHealthWarningShown = false
        lastUrgentWarningAt = 0
        breakCyclesToday = 0
        breakInProgress = false
        stats.resetSession()
        timeline.record(.sessionReset)
    }

    /// Call when a stretch overlay appears.
    func breakDidStart() { breakInProgress = true }

    /// Call when a stretch overlay is dismissed.
    /// - Parameter completed: true if the user completed the full stretch, false if skipped.
    func breakDidEnd(completed: Bool) {
        breakInProgress = false
        timeline.record(completed ? .breakCompleted : .breakSkipped)
        if completed {
            continuousSittingSeconds = 0
            firmHealthWarningShown = false
            urgentHealthWarningShown = false
            lastUrgentWarningAt = 0
        }
    }

    /// Manually trigger a break right now (e.g., user feels stiffness).
    func triggerBreakNow() {
        // Reset state BEFORE dispatching to avoid race with tick()
        activeSecondsSinceLastReminder = 0
        snoozesUsedThisCycle = 0
        warningShownThisCycle = false
        postureNudgeShownThisCycle = false

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onDismissWarning?()
            if self.blockingModeEnabled {
                self.breakInProgress = true
                self.onStretchBreak?(self.adaptiveBreakDuration)
            }
        }
    }

    /// Snooze the current break. First snooze = 5min, second = 2min.
    func snooze() {
        guard snoozesUsedThisCycle < Self.maxSnoozesPerCycle else { return }
        let snoozeAmount = Self.snoozeDurations[snoozesUsedThisCycle]
        snoozesUsedThisCycle += 1
        warningShownThisCycle = false
        stats.recordBreakSnoozed()
        timeline.record(.breakSnoozed, detail: "\(Int(snoozeAmount / 60))m")
        activeSecondsSinceLastReminder = max(0, activeSecondsSinceLastReminder - snoozeAmount)

        DispatchQueue.main.async { [weak self] in
            self?.onDismissWarning?()
        }
    }

    var canSnooze: Bool {
        snoozesUsedThisCycle < Self.maxSnoozesPerCycle
    }

    /// Human-readable description of the next snooze duration.
    var nextSnoozeLabel: String {
        guard canSnooze else { return "" }
        let seconds = Self.snoozeDurations[snoozesUsedThisCycle]
        return "\(Int(seconds / 60))m"
    }

    /// Adaptive break duration: increases by 15s per cycle, capped at 120s or
    /// the user's configured duration (whichever is larger — never reduce their setting).
    var adaptiveBreakDuration: Int {
        let cap = max(stretchDurationSeconds, 120)
        return min(stretchDurationSeconds + breakCyclesToday * 15, cap)
    }

    // MARK: - Meeting Detection

    /// Returns true if a known video-call / screen-sharing app is running AND
    /// a microphone is actively being captured — indicating a live call.
    ///
    /// Checking only whether the app process is alive is insufficient because
    /// apps like Teams and Zoom keep running as background processes long after
    /// a meeting ends, which causes the break to stay deferred forever.
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

        // A meeting app is running — but is a call actually in progress?
        // Check whether any microphone is actively being captured.  Meeting
        // apps keep the audio HAL device open for the entire call (even when
        // the user mutes), so this reliably indicates an active meeting.
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
            // Only consider devices that have input streams (i.e. microphones).
            var inputStreamAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(
                device, &inputStreamAddr, 0, nil, &streamSize
            ) == noErr, streamSize > 0 else { continue }

            // Check if this input-capable device is currently being used.
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

    // MARK: - Tick

    private func tick() {
        let active = activityMonitor.isUserActive()
        let inMeeting = isInMeeting()

        // Record timeline transitions (idle ↔ active, meeting start/end)
        if active && !wasActive && !breakInProgress {
            timeline.record(.workStarted)
        } else if !active && wasActive && !breakInProgress {
            timeline.record(.workEnded)
        }
        if inMeeting && !wasInMeeting {
            timeline.record(.meetingStarted)
        } else if !inMeeting && wasInMeeting {
            timeline.record(.meetingEnded)
        }
        wasActive = active
        wasInMeeting = inMeeting

        // Meeting time counts (still sitting), but stretch break time doesn't
        if active && !breakInProgress {
            activeSecondsSinceLastReminder += pollInterval
            totalActiveSeconds += pollInterval
        }

        // Track continuous sitting — counts meeting time too since the user is
        // still seated.  Only resets when a break is completed or user goes idle.
        if (active || inMeeting) && !breakInProgress {
            continuousSittingSeconds += pollInterval
            stats.updateLongestContinuousSitting(continuousSittingSeconds)
        } else if !active && !inMeeting && continuousSittingSeconds > 0 {
            // User went idle outside a meeting — likely stood up
            continuousSittingSeconds = 0
            firmHealthWarningShown = false
            urgentHealthWarningShown = false
            lastUrgentWarningAt = 0
        }

        onTick?(totalActiveSeconds, activeSecondsSinceLastReminder, active, inMeeting)

        let thresholdSeconds = TimeInterval(reminderIntervalMinutes) * 60
        let timeUntilBreak = thresholdSeconds - activeSecondsSinceLastReminder

        // Posture micro-nudge at the halfway point (suppress during meetings)
        if !postureNudgeShownThisCycle && !inMeeting && activeSecondsSinceLastReminder >= (thresholdSeconds / 2) && timeUntilBreak > warningLeadTimeSeconds {
            postureNudgeShownThisCycle = true
            DispatchQueue.main.async { [weak self] in
                self?.onPostureNudge?()
            }
        }

        // Show warning banner before the break (suppress during meetings)
        if blockingModeEnabled && !warningShownThisCycle && !inMeeting && timeUntilBreak <= warningLeadTimeSeconds && timeUntilBreak > 0 {
            warningShownThisCycle = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onWarning?(Int(timeUntilBreak), self.canSnooze)
            }
        }

        // Health warnings for prolonged continuous sitting (suppress during meetings)
        if !inMeeting && !breakInProgress {
            let continuousMinutes = Int(continuousSittingSeconds) / 60
            if continuousSittingSeconds >= Self.urgentWarningThreshold {
                if !urgentHealthWarningShown {
                    urgentHealthWarningShown = true
                    lastUrgentWarningAt = continuousSittingSeconds
                    stats.recordHealthWarning()
                    timeline.record(.healthWarning, detail: "\(continuousMinutes) min (urgent)")
                    DispatchQueue.main.async { [weak self] in
                        self?.onHealthWarning?(continuousMinutes, true)
                    }
                } else if continuousSittingSeconds - lastUrgentWarningAt >= Self.urgentRepeatInterval {
                    lastUrgentWarningAt = continuousSittingSeconds
                    stats.recordHealthWarning()
                    timeline.record(.healthWarning, detail: "\(continuousMinutes) min (urgent)")
                    DispatchQueue.main.async { [weak self] in
                        self?.onHealthWarning?(continuousMinutes, true)
                    }
                }
            } else if continuousSittingSeconds >= Self.firmWarningThreshold && !firmHealthWarningShown {
                firmHealthWarningShown = true
                stats.recordHealthWarning()
                timeline.record(.healthWarning, detail: "\(continuousMinutes) min")
                DispatchQueue.main.async { [weak self] in
                    self?.onHealthWarning?(continuousMinutes, false)
                }
            }
        }

        if activeSecondsSinceLastReminder >= thresholdSeconds {
            if inMeeting {
                // Defer — don't reset the timer, fire as soon as meeting ends
                return
            }
            fireReminder()
            activeSecondsSinceLastReminder = 0
            snoozesUsedThisCycle = 0
            warningShownThisCycle = false
            postureNudgeShownThisCycle = false
        }
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

        // tick() already verified we're NOT in a meeting before calling this
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onDismissWarning?()
            if self.blockingModeEnabled {
                self.breakInProgress = true
                self.onStretchBreak?(duration)
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
