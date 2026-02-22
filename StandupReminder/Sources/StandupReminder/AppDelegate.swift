import Cocoa
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let reminderManager = ReminderManager()
    private var preferencesWindowController: PreferencesWindowController?
    private let stretchOverlay = StretchOverlayWindowController()
    private let warningBanner = WarningBannerController()

    // Menu items we update dynamically
    private var timerMenuItem: NSMenuItem!
    private var statusMenuItem: NSMenuItem!
    private var streakMenuItem: NSMenuItem!
    private var breaksMenuItem: NSMenuItem!
    private var toggleMenuItem: NSMenuItem!

    private var isTracking = true

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupMenu()

        reminderManager.onTick = { [weak self] totalActive, sinceLast, isActive in
            DispatchQueue.main.async {
                self?.updateMenuBarDisplay(totalActive: totalActive, sinceLast: sinceLast, isActive: isActive)
            }
        }

        reminderManager.onWarning = { [weak self] secondsUntilBreak, canSnooze in
            self?.warningBanner.show(secondsUntilBreak: secondsUntilBreak, canSnooze: canSnooze) { [weak self] in
                self?.reminderManager.snooze()
            }
        }

        reminderManager.onDismissWarning = { [weak self] in
            self?.warningBanner.dismiss()
        }

        reminderManager.onStretchBreak = { [weak self] durationSeconds in
            self?.stretchOverlay.show(stretchDurationSeconds: durationSeconds) { [weak self] wasSkipped in
                if wasSkipped {
                    self?.reminderManager.stats.recordBreakSkipped()
                } else {
                    self?.reminderManager.stats.recordBreakCompleted()
                }
                self?.updateStatsMenuItems()
            }
        }

        reminderManager.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        reminderManager.stop()
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

        statusMenuItem = NSMenuItem(title: "Next reminder in: --", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        menu.addItem(.separator())

        breaksMenuItem = NSMenuItem(title: "Breaks today: 0", action: nil, keyEquivalent: "")
        breaksMenuItem.isEnabled = false
        menu.addItem(breaksMenuItem)

        streakMenuItem = NSMenuItem(title: "Streak: \(reminderManager.stats.dailyStreak) day(s)", action: nil, keyEquivalent: "")
        streakMenuItem.isEnabled = false
        menu.addItem(streakMenuItem)

        menu.addItem(.separator())

        toggleMenuItem = NSMenuItem(title: "Pause Tracking", action: #selector(toggleTracking), keyEquivalent: "p")
        toggleMenuItem.target = self
        menu.addItem(toggleMenuItem)

        let resetItem = NSMenuItem(title: "Reset Session", action: #selector(resetSession), keyEquivalent: "r")
        resetItem.target = self
        menu.addItem(resetItem)

        menu.addItem(.separator())

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

    private func updateMenuBarDisplay(totalActive: TimeInterval, sinceLast: TimeInterval, isActive: Bool) {
        let totalMinutes = Int(totalActive) / 60
        let hours = totalMinutes / 60
        let mins = totalMinutes % 60

        let timeString: String
        if hours > 0 {
            timeString = "\(hours)h\(mins)m"
        } else {
            timeString = "\(mins)m"
        }

        statusItem.button?.title = " \(timeString)"

        // Update menu items
        if hours > 0 {
            timerMenuItem.title = "Working: \(hours)h \(mins)m"
        } else {
            timerMenuItem.title = "Working: \(mins)m"
        }

        let intervalSeconds = TimeInterval(reminderManager.reminderIntervalMinutes) * 60
        let remaining = max(0, intervalSeconds - sinceLast)
        let remainingMins = Int(remaining) / 60
        let remainingSecs = Int(remaining) % 60

        if isActive {
            statusMenuItem.title = "Next reminder in: \(remainingMins)m \(remainingSecs)s"
        } else {
            statusMenuItem.title = "Status: Idle (paused)"
        }
    }

    private func updateStatsMenuItems() {
        let stats = reminderManager.stats
        breaksMenuItem.title = "Breaks today: \(stats.breaksCompleted) completed, \(stats.breaksSkipped) skipped"
        let streak = stats.dailyStreak
        streakMenuItem.title = "Streak: \(streak) day\(streak == 1 ? "" : "s")"
    }

    // MARK: - Session Summary on Quit

    private func showSessionSummaryIfNeeded() {
        let stats = reminderManager.stats
        // Only show if the user actually did some work
        guard reminderManager.totalActiveSeconds > 60 else { return }

        let summary = stats.sessionSummary(totalWorkSeconds: reminderManager.totalActiveSeconds)

        let alert = NSAlert()
        alert.messageText = "Session Complete"
        alert.informativeText = summary
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.icon = NSImage(systemSymbolName: "figure.stand", accessibilityDescription: nil)
        alert.runModal()
    }

    // MARK: - Actions

    @objc private func toggleTracking() {
        isTracking.toggle()
        if isTracking {
            reminderManager.start()
            toggleMenuItem.title = "Pause Tracking"
        } else {
            reminderManager.stop()
            toggleMenuItem.title = "Resume Tracking"
            statusMenuItem.title = "Status: Paused"
        }
    }

    @objc private func resetSession() {
        reminderManager.resetSession()
        statusItem.button?.title = " 0m"
        timerMenuItem.title = "Working: 0m"
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

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
