import Cocoa
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let reminderManager = ReminderManager()
    private var preferencesWindowController: PreferencesWindowController?
    private var statsWindowController: StatsViewerWindowController?
    private var timelineWindowController: DailyTimelineWindowController?
    private let stretchOverlay = StretchOverlayWindowController()
    private let warningBanner = WarningBannerController()

    // Menu items we update dynamically
    private var timerMenuItem: NSMenuItem!
    private var statusMenuItem: NSMenuItem!
    private var streakMenuItem: NSMenuItem!
    private var breaksMenuItem: NSMenuItem!
    private var disableMenuItem: NSMenuItem!
    private var resumeMenuItem: NSMenuItem!

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupMenu()

        reminderManager.onTick = { [weak self] totalActive, sinceLast, isActive, inMeeting in
            DispatchQueue.main.async {
                self?.updateMenuBarDisplay(totalActive: totalActive, sinceLast: sinceLast, isActive: isActive, inMeeting: inMeeting)
            }
            // Persist work time to the daily store every tick (~5s)
            DailyStatsStore.shared.updateTotalWorkSeconds(totalActive)
        }

        reminderManager.onWarning = { [weak self] secondsUntilBreak, canSnooze in
            guard let self else { return }
            self.warningBanner.show(
                secondsUntilBreak: secondsUntilBreak,
                canSnooze: canSnooze,
                snoozeLabel: self.reminderManager.nextSnoozeLabel
            ) { [weak self] in
                self?.reminderManager.snooze()
            }
        }

        reminderManager.onDismissWarning = { [weak self] in
            self?.warningBanner.dismiss()
        }

        reminderManager.onStretchBreak = { [weak self] durationSeconds in
            self?.stretchOverlay.show(stretchDurationSeconds: durationSeconds) { [weak self] wasSkipped in
                self?.reminderManager.breakDidEnd(completed: !wasSkipped)
                if wasSkipped {
                    self?.reminderManager.stats.recordBreakSkipped()
                } else {
                    self?.reminderManager.stats.recordBreakCompleted()
                }
                self?.updateStatsMenuItems()
            }
        }

        reminderManager.onPostureNudge = { [weak self] in
            self?.showPostureNudge()
        }

        reminderManager.onHealthWarning = { [weak self] continuousMinutes, isUrgent in
            self?.showHealthWarning(continuousMinutes: continuousMinutes, isUrgent: isUrgent)
        }

        reminderManager.onDisableStateChanged = { [weak self] disabled, until in
            self?.updateDisableUI(disabled: disabled, until: until)
        }

        reminderManager.start()

        // Prune old timeline files in the background
        DispatchQueue.global(qos: .utility).async {
            DailyTimelineStore.pruneOldFiles()
        }

        // Start the auto-updater
        AutoUpdater.shared.startPeriodicChecks()
    }

    func applicationWillTerminate(_ notification: Notification) {
        reminderManager.stop()
        AutoUpdater.shared.stopPeriodicChecks()
        DailyStatsStore.shared.updateTotalWorkSeconds(reminderManager.totalActiveSeconds)
        DailyStatsStore.shared.flush()
        showSessionSummaryIfNeeded()
    }

    // MARK: - Status Bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            if let image = NSImage(systemSymbolName: "figure.stand", accessibilityDescription: "Standup Reminder") {
                let configured = image.withSymbolConfiguration(config) ?? image
                button.image = configured
            }
            button.imagePosition = .imageLeading
            button.title = " 0m"
        }
    }

    private func setupMenu() {
        let menu = NSMenu()

        timerMenuItem = NSMenuItem(title: "Working: 0m", action: nil, keyEquivalent: "")
        timerMenuItem.isEnabled = false
        menu.addItem(timerMenuItem)

        statusMenuItem = NSMenuItem(title: "Next break: --", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        menu.addItem(.separator())

        breaksMenuItem = NSMenuItem(title: "Breaks today: 0", action: nil, keyEquivalent: "")
        breaksMenuItem.isEnabled = false
        menu.addItem(breaksMenuItem)

        let streak = reminderManager.stats.dailyStreak
        streakMenuItem = NSMenuItem(title: "Streak: \(streak) day\(streak == 1 ? "" : "s")", action: nil, keyEquivalent: "")
        streakMenuItem.isEnabled = false
        menu.addItem(streakMenuItem)

        let statsItem = NSMenuItem(title: "View Stats…", action: #selector(openStats), keyEquivalent: "s")
        statsItem.target = self
        menu.addItem(statsItem)

        let timelineItem = NSMenuItem(title: "Today's Timeline…", action: #selector(openTimeline), keyEquivalent: "t")
        timelineItem.target = self
        menu.addItem(timelineItem)

        menu.addItem(.separator())

        // "Break Now" — for when your back tells you NOW
        let breakNowItem = NSMenuItem(title: "Break Now", action: #selector(breakNow), keyEquivalent: "b")
        breakNowItem.target = self
        menu.addItem(breakNowItem)

        // "Disable for..." submenu
        disableMenuItem = NSMenuItem(title: "Disable for…", action: nil, keyEquivalent: "")
        let disableSubmenu = NSMenu()

        let disable15 = NSMenuItem(title: "15 minutes", action: #selector(disable15min), keyEquivalent: "")
        disable15.target = self
        disableSubmenu.addItem(disable15)

        let disable30 = NSMenuItem(title: "30 minutes", action: #selector(disable30min), keyEquivalent: "")
        disable30.target = self
        disableSubmenu.addItem(disable30)

        let disable60 = NSMenuItem(title: "1 hour", action: #selector(disable1hr), keyEquivalent: "")
        disable60.target = self
        disableSubmenu.addItem(disable60)

        let disable120 = NSMenuItem(title: "2 hours", action: #selector(disable2hr), keyEquivalent: "")
        disable120.target = self
        disableSubmenu.addItem(disable120)

        disableSubmenu.addItem(.separator())

        let disableRest = NSMenuItem(title: "Until I turn it back on", action: #selector(disableIndefinitely), keyEquivalent: "")
        disableRest.target = self
        disableSubmenu.addItem(disableRest)

        disableMenuItem.submenu = disableSubmenu
        menu.addItem(disableMenuItem)

        // "Resume" item — hidden until disabled
        resumeMenuItem = NSMenuItem(title: "Resume Tracking", action: #selector(resumeTracking), keyEquivalent: "p")
        resumeMenuItem.target = self
        resumeMenuItem.isHidden = true
        menu.addItem(resumeMenuItem)

        let resetItem = NSMenuItem(title: "Reset Session", action: #selector(resetSession), keyEquivalent: "r")
        resetItem.target = self
        menu.addItem(resetItem)

        menu.addItem(.separator())

        let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "u")
        updateItem.target = self
        menu.addItem(updateItem)

        let prefsItem = NSMenuItem(title: "Preferences…", action: #selector(openPreferences), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit StandupReminder", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - Display Updates

    private func updateMenuBarDisplay(totalActive: TimeInterval, sinceLast: TimeInterval, isActive: Bool, inMeeting: Bool) {
        // Don't overwrite the "Disabled until..." status if a stale tick was queued
        guard !reminderManager.isDisabled else { return }

        let totalMinutes = Int(totalActive) / 60
        let hours = totalMinutes / 60
        let mins = totalMinutes % 60

        let timeString: String
        if hours > 0 {
            timeString = "\(hours)h\(mins)m"
        } else {
            timeString = "\(mins)m"
        }

        // Swap to warning icon when sitting 90+ min without a completed break
        if let button = statusItem.button {
            if reminderManager.isUrgentSittingWarning {
                let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .bold)
                if let warnImage = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                           accessibilityDescription: "Prolonged sitting warning")?
                    .withSymbolConfiguration(config) {
                    button.image = warnImage
                }
            } else {
                let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
                if let normalImage = NSImage(systemSymbolName: "figure.stand",
                                             accessibilityDescription: "Standup Reminder")?
                    .withSymbolConfiguration(config) {
                    button.image = normalImage
                }
            }
        }

        statusItem.button?.title = " \(timeString)"

        if hours > 0 {
            timerMenuItem.title = "Working: \(hours)h \(mins)m"
        } else {
            timerMenuItem.title = "Working: \(mins)m"
        }

        let intervalSeconds = TimeInterval(reminderManager.reminderIntervalMinutes) * 60
        let remaining = max(0, intervalSeconds - sinceLast)
        let remainingMins = Int(remaining) / 60
        let remainingSecs = Int(remaining) % 60

        if inMeeting {
            statusMenuItem.title = "In meeting — break deferred"
        } else if isActive {
            statusMenuItem.title = "Next break: \(remainingMins)m \(remainingSecs)s"
        } else {
            statusMenuItem.title = "Idle — timer paused"
        }
    }

    private func updateStatsMenuItems() {
        let stats = reminderManager.stats
        breaksMenuItem.title = "Breaks today: \(stats.breaksCompleted) completed, \(stats.breaksSkipped) skipped"
        let streak = stats.dailyStreak
        streakMenuItem.title = "Streak: \(streak) day\(streak == 1 ? "" : "s")"
    }

    // MARK: - Health Warning Notifications

    /// Rotating urgent messages — each highlights a different science-backed risk
    /// so repeated 10-minute alerts don't become wallpaper.
    ///
    /// Sources:
    ///   Disc pressure  — Wilke et al., Spine 1999
    ///   Leg blood flow — Thosar et al., Med Sci Sports Exerc 2015
    ///   DVT dose-resp  — Healy et al., J R Soc Med 2010
    ///   Enzyme/EMG     — Bey & Hamilton, J Physiol 2003
    ///   Mortality      — Ekelund et al., Lancet 2016
    ///   Life expect.   — Veerman et al., Br J Sports Med 2012
    ///   Disc nutrition — Urban et al., Spine 2004
    private static let urgentWarnings: [(title: String, body: String)] = [
        (
            title: "Your Spinal Discs Are Starving",
            body: "Your spinal discs have zero blood supply. The only way they get oxygen and nutrients is through movement — a pumping action when you stand, walk, and bend. %d minutes of sitting still is starving them. This is exactly how disc herniations and chronic back pain start. (Source: Urban et al., Spine 2004)"
        ),
        (
            title: "Blood Clot Risk Is Rising",
            body: "%d minutes without standing. Your risk of a dangerous blood clot in your legs goes up about 20%% for every hour you sit without getting up. If that clot travels to your lungs, it can kill you within hours. This happens to roughly 100,000 people a year. Stand up and walk for 2 minutes. (Source: Healy et al., J R Soc Med 2010)"
        ),
        (
            title: "Your Muscles Are Shutting Down",
            body: "Your leg muscles have nearly switched off — electrical activity is at 1%% of normal. The enzyme that clears fat from your blood has dropped by up to 95%%. This leads to type 2 diabetes and heart disease over time. The worst part: going to the gym later won't undo this. You have to break the sitting. Now. (Source: Hamilton et al., J Physiol 2003)"
        ),
        (
            title: "You Are Shortening Your Life",
            body: "You've been sitting for %d minutes straight. A study of over 1 million people found this level of sitting raises your risk of early death by 59%%. Each unbroken hour costs about 22 minutes of life expectancy — roughly the same as smoking two cigarettes. This damage builds up the longer you sit. (Sources: Ekelund, Lancet 2016; Veerman, Br J Sports Med 2012)"
        ),
    ]

    private func showHealthWarning(continuousMinutes: Int, isUrgent: Bool) {
        let content = UNMutableNotificationContent()

        if isUrgent {
            // Rotate through urgent messages based on how long they've been sitting
            let index = ((continuousMinutes - 90) / 10) % Self.urgentWarnings.count
            let warning = Self.urgentWarnings[max(0, index)]
            content.title = warning.title
            content.body = String(format: warning.body, continuousMinutes, continuousMinutes)
            content.sound = UNNotificationSound.default
        } else {
            content.title = "\(continuousMinutes) Minutes Without Moving"
            content.body = "Slouching at your desk puts up to 66% more pressure on your spinal discs than standing (Wilke, Spine 1999). Blood flow in your legs has dropped by half (Thosar, MSSE 2015). Your blood clot risk grows 20% every hour you sit still (Healy, JRSM 2010). Get up — even 60 seconds helps."
            content.sound = UNNotificationSound.default
        }

        let request = UNNotificationRequest(
            identifier: isUrgent ? "health-warning-urgent" : "health-warning-firm",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Posture Micro-Nudge

    private func showPostureNudge() {
        // Brief flash of the menu bar icon + a subtle notification
        guard let button = statusItem.button else { return }

        // Flash the icon orange briefly
        let originalImage = button.image
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        if let alertImage = NSImage(systemSymbolName: "arrow.up.message", accessibilityDescription: "Check posture")?
            .withSymbolConfiguration(config) {
            button.image = alertImage
        }

        // Restore after 3 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            button.image = originalImage
        }

        // Send a quiet notification (no sound)
        let content = UNMutableNotificationContent()
        content.title = "Posture Check"
        content.body = "Sit up straight. Shoulders back. Is your screen at eye level?"
        // No sound — this should be gentle

        let request = UNNotificationRequest(
            identifier: "posture-nudge",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Session Summary on Quit

    private func showSessionSummaryIfNeeded() {
        let stats = reminderManager.stats
        guard reminderManager.totalActiveSeconds > 60 else { return }

        let summary = stats.sessionSummary(totalWorkSeconds: reminderManager.totalActiveSeconds)

        // Use a system notification instead of runModal() — a modal dialog during
        // applicationWillTerminate blocks the process and hangs during system shutdown.
        let content = UNMutableNotificationContent()
        content.title = "Session Complete"
        content.body = summary
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: "session-summary",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Actions

    @objc private func breakNow() {
        reminderManager.triggerBreakNow()
    }

    @objc private func disable15min() { warningBanner.dismiss(); reminderManager.disableFor(minutes: 15) }
    @objc private func disable30min() { warningBanner.dismiss(); reminderManager.disableFor(minutes: 30) }
    @objc private func disable1hr() { warningBanner.dismiss(); reminderManager.disableFor(minutes: 60) }
    @objc private func disable2hr() { warningBanner.dismiss(); reminderManager.disableFor(minutes: 120) }
    @objc private func disableIndefinitely() { warningBanner.dismiss(); reminderManager.disableIndefinitely() }

    @objc private func resumeTracking() {
        reminderManager.resumeFromDisable()
    }

    private func updateDisableUI(disabled: Bool, until: Date?) {
        disableMenuItem.isHidden = disabled
        resumeMenuItem.isHidden = !disabled

        if disabled {
            if let until, until != .distantFuture {
                let formatter = DateFormatter()
                formatter.dateFormat = "h:mm a"
                let timeStr = formatter.string(from: until)
                statusMenuItem.title = "Disabled until \(timeStr)"
                resumeMenuItem.title = "Resume Tracking (auto at \(timeStr))"
            } else {
                statusMenuItem.title = "Disabled — click Resume to restart"
                resumeMenuItem.title = "Resume Tracking"
            }
            statusItem.button?.title = " OFF"
        } else {
            statusItem.button?.title = " 0m"
            statusMenuItem.title = "Next break: --"
            resumeMenuItem.title = "Resume Tracking"
        }
    }

    @objc private func resetSession() {
        warningBanner.dismiss()
        reminderManager.resetSession()
        statusItem.button?.title = " 0m"
        timerMenuItem.title = "Working: 0m"
        statusMenuItem.title = "Next break: --"
        updateStatsMenuItems()
    }

    @objc private func checkForUpdates() {
        AutoUpdater.shared.checkForUpdates(userInitiated: true)
    }

    @objc private func openTimeline() {
        // Recreate each time so the view picks up the latest events
        timelineWindowController = DailyTimelineWindowController(
            store: reminderManager.timeline,
            totalActiveSeconds: reminderManager.totalActiveSeconds
        )
        timelineWindowController?.showWindow()
    }

    @objc private func openPreferences() {
        if preferencesWindowController == nil {
            preferencesWindowController = PreferencesWindowController { [weak self] interval, idle, blocking, stretchDuration in
                self?.reminderManager.reminderIntervalMinutes = interval
                self?.reminderManager.idleThresholdSeconds = idle
                self?.reminderManager.blockingModeEnabled = blocking
                self?.reminderManager.stretchDurationSeconds = stretchDuration
            }
        }
        preferencesWindowController?.showWindow()
    }

    @objc private func openStats() {
        let stats = reminderManager.stats
        // Re-create each time so live values are fresh
        statsWindowController = StatsViewerWindowController(
            breaksCompleted: stats.breaksCompleted,
            breaksSkipped: stats.breaksSkipped,
            breaksSnoozed: stats.breaksSnoozed,
            healthWarnings: stats.healthWarningsReceived,
            longestSitting: stats.longestContinuousSittingSeconds,
            totalWorkSeconds: reminderManager.totalActiveSeconds
        )
        statsWindowController?.showWindow()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
