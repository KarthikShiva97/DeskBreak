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

    /// How often (in minutes) to send a standup reminder. Defaults to 30.
    var reminderIntervalMinutes: Int = 30 {
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

    /// Whether a snooze has already been used for the current break cycle.
    private var snoozeUsedThisCycle = false

    /// Whether the warning has been shown for the current cycle.
    private var warningShownThisCycle = false

    /// Callback fired every poll tick so the UI can update the displayed time.
    var onTick: ((_ totalActive: TimeInterval, _ sinceLast: TimeInterval, _ isActive: Bool) -> Void)?

    /// Callback fired when a blocking stretch break should be shown.
    var onStretchBreak: ((_ durationSeconds: Int) -> Void)?

    /// Callback fired when a warning banner should appear before the break.
    var onWarning: ((_ secondsUntilBreak: Int, _ canSnooze: Bool) -> Void)?

    /// Callback to dismiss the warning banner.
    var onDismissWarning: (() -> Void)?

    /// How often we poll for idle state (seconds).
    private let pollInterval: TimeInterval = 5

    override init() {
        super.init()
        reminderIntervalMinutes = UserDefaults.standard.object(forKey: "reminderIntervalMinutes") as? Int ?? 30
        if let saved = UserDefaults.standard.object(forKey: "idleThresholdSeconds") as? Double, saved > 0 {
            activityMonitor.idleThresholdSeconds = saved
        }
        blockingModeEnabled = UserDefaults.standard.object(forKey: "blockingModeEnabled") as? Bool ?? true
        stretchDurationSeconds = UserDefaults.standard.object(forKey: "stretchDurationSeconds") as? Int ?? 60
    }

    // MARK: - Lifecycle

    func start() {
        requestNotificationPermission()
        UNUserNotificationCenter.current().delegate = self
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func resetSession() {
        activeSecondsSinceLastReminder = 0
        totalActiveSeconds = 0
        snoozeUsedThisCycle = false
        warningShownThisCycle = false
    }

    /// Snooze the current break by 5 minutes. Only allowed once per cycle.
    func snooze() {
        guard !snoozeUsedThisCycle else { return }
        snoozeUsedThisCycle = true
        warningShownThisCycle = false
        stats.recordBreakSnoozed()
        // Push the break 5 minutes into the future by rolling back the counter
        let snoozeAmount: TimeInterval = 5 * 60
        activeSecondsSinceLastReminder = max(0, activeSecondsSinceLastReminder - snoozeAmount)

        DispatchQueue.main.async { [weak self] in
            self?.onDismissWarning?()
        }
    }

    // MARK: - Tick

    private func tick() {
        let active = activityMonitor.isUserActive()
        if active {
            activeSecondsSinceLastReminder += pollInterval
            totalActiveSeconds += pollInterval
        }

        onTick?(totalActiveSeconds, activeSecondsSinceLastReminder, active)

        let thresholdSeconds = TimeInterval(reminderIntervalMinutes) * 60
        let timeUntilBreak = thresholdSeconds - activeSecondsSinceLastReminder

        // Show warning banner before the break
        if blockingModeEnabled && !warningShownThisCycle && timeUntilBreak <= warningLeadTimeSeconds && timeUntilBreak > 0 {
            warningShownThisCycle = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onWarning?(Int(timeUntilBreak), !self.snoozeUsedThisCycle)
            }
        }

        if activeSecondsSinceLastReminder >= thresholdSeconds {
            fireReminder()
            activeSecondsSinceLastReminder = 0
            snoozeUsedThisCycle = false
            warningShownThisCycle = false
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
        let content = UNMutableNotificationContent()
        content.title = "Standup Reminder"
        let minutes = Int(totalActiveSeconds) / 60
        content.body = "You've been working for \(minutes) minutes. Time to stand up, stretch, and take a break!"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "standup-\(UUID().uuidString)",
            content: content,
            trigger: nil // Fire immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Failed to deliver notification: \(error.localizedDescription)")
            }
        }

        // Dismiss warning banner and show blocking overlay
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onDismissWarning?()
            if self.blockingModeEnabled {
                self.onStretchBreak?(self.stretchDurationSeconds)
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show notifications even when the app is in the foreground.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
