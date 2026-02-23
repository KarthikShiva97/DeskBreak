import Cocoa
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
        let until = Date().addingTimeInterval(TimeInterval(minutes * 60))
        disabledUntil = until
        onDisableStateChanged?(true, until)

        resumeTimer?.invalidate()
        resumeTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: false) { [weak self] _ in
            self?.resumeFromDisable()
        }
    }

    /// Disable tracking indefinitely until manually resumed.
    func disableIndefinitely() {
        stop()
        disabledUntil = .distantFuture
        resumeTimer?.invalidate()
        resumeTimer = nil
        onDisableStateChanged?(true, .distantFuture)
    }

    /// Resume tracking (called by auto-timer or manually).
    func resumeFromDisable() {
        resumeTimer?.invalidate()
        resumeTimer = nil
        disabledUntil = nil
        activeSecondsSinceLastReminder = 0
        snoozesUsedThisCycle = 0
        warningShownThisCycle = false
        postureNudgeShownThisCycle = false
        start()
        onDisableStateChanged?(false, nil)
    }

    var isDisabled: Bool {
        disabledUntil != nil
    }

    func resetSession() {
        activeSecondsSinceLastReminder = 0
        totalActiveSeconds = 0
        snoozesUsedThisCycle = 0
        warningShownThisCycle = false
        postureNudgeShownThisCycle = false
        breakCyclesToday = 0
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

    /// Adaptive break duration: increases by 15s per cycle, capped at 120s.
    /// Your spine needs more decompression the longer you sit.
    var adaptiveBreakDuration: Int {
        min(stretchDurationSeconds + breakCyclesToday * 15, 120)
    }

    // MARK: - Meeting Detection

    /// Returns true if a known video call or screen-sharing app is running.
    /// Used to pause the work timer during meetings and defer overlay breaks.
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

        for app in NSWorkspace.shared.runningApplications {
            if let bundleID = app.bundleIdentifier,
               meetingBundleIDs.contains(where: { bundleID.hasPrefix($0) }),
               !app.isTerminated {
                return true
            }
            if let name = app.localizedName,
               meetingNameFragments.contains(where: { name.contains($0) }),
               !app.isTerminated {
                return true
            }
        }
        return false
    }

    // MARK: - Tick

    private func tick() {
        let active = activityMonitor.isUserActive()
        let inMeeting = isInMeeting()

        // Meeting time still counts — you're sitting either way
        if active {
            activeSecondsSinceLastReminder += pollInterval
            totalActiveSeconds += pollInterval
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
        let sharing = isInMeeting()

        let content = UNMutableNotificationContent()
        content.title = sharing ? "Standup Reminder (meeting detected)" : "Standup Reminder"
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
            if self.blockingModeEnabled && !sharing {
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
