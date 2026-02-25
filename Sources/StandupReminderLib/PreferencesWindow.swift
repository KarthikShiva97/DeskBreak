import ServiceManagement
import SwiftUI

/// SwiftUI view for configuring reminder settings.
struct PreferencesView: View {
    @AppStorage("reminderIntervalMinutes") private var intervalMinutes: Int = 25
    @AppStorage("idleThresholdSeconds") private var idleThreshold: Double = 120
    @AppStorage("blockingModeEnabled") private var blockingMode: Bool = true
    @AppStorage("stretchDurationSeconds") private var stretchDuration: Int = 60
    @AppStorage("launchAtLogin") private var launchAtLogin: Bool = false
    @AppStorage("autoUpdater_enabled") private var autoUpdateEnabled: Bool = true

    /// Called when the user changes settings so the ReminderManager can pick them up.
    var onSettingsChanged: ((_ intervalMinutes: Int, _ idleThreshold: Double, _ blockingMode: Bool, _ stretchDuration: Int) -> Void)?

    private let intervalOptions = [15, 20, 25, 30, 45, 60]
    private let idleOptions: [(label: String, seconds: Double)] = [
        ("1 minute", 60),
        ("2 minutes", 120),
        ("3 minutes", 180),
        ("5 minutes", 300),
        ("10 minutes", 600),
    ]
    private let stretchDurationOptions: [(label: String, seconds: Int)] = [
        ("30 seconds", 30),
        ("1 minute", 60),
        ("2 minutes", 120),
        ("3 minutes", 180),
        ("5 minutes", 300),
    ]

    var body: some View {
        Form {
            Section {
                Picker("Remind me every:", selection: $intervalMinutes) {
                    ForEach(intervalOptions, id: \.self) { mins in
                        Text("\(mins) minutes").tag(mins)
                    }
                }
                .onChange(of: intervalMinutes) { _, _ in
                    notifyChange()
                }

                Picker("Consider me idle after:", selection: $idleThreshold) {
                    ForEach(idleOptions, id: \.seconds) { option in
                        Text(option.label).tag(option.seconds)
                    }
                }
                .onChange(of: idleThreshold) { _, _ in
                    notifyChange()
                }

                Text("25 minutes is recommended for spinal disc issues. Shorter = better for your back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Reminder Settings", systemImage: "timer")
            }

            Section {
                Toggle("Block screen until stretching is done", isOn: $blockingMode)
                    .onChange(of: blockingMode) { _, _ in
                        notifyChange()
                    }

                if blockingMode {
                    Picker("Stretch break duration:", selection: $stretchDuration) {
                        ForEach(stretchDurationOptions, id: \.seconds) { option in
                            Text(option.label).tag(option.seconds)
                        }
                    }
                    .onChange(of: stretchDuration) { _, _ in
                        notifyChange()
                    }

                    Text("Full-screen overlay blocks your work until the timer finishes. You can skip after 10 seconds. Automatically deferred during screen sharing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Label("Break Enforcement", systemImage: "hand.raised")
            }

            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            print("Failed to update login item: \(error)")
                            launchAtLogin = !newValue
                        }
                    }
                    .onAppear {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }

                Text("Recommended — the app works best when it starts automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Automatically check for updates", isOn: $autoUpdateEnabled)
                    .onChange(of: autoUpdateEnabled) { _, newValue in
                        AutoUpdater.shared.isAutoUpdateEnabled = newValue
                    }

                Text("Checks for new versions on GitHub every few hours and prompts you to update.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("General", systemImage: "gear")
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Snooze: 2 per break (5min, then 2min)")
                    Text("Posture nudge: silent reminder at halfway")
                    Text("Break Now: Cmd+B in the menu bar")
                    Text("Meetings: break deferred until call ends")
                    Text("Adaptive breaks: duration increases the longer you sit")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } header: {
                Label("How it works", systemImage: "questionmark.circle")
            }

            Section {
                LabeledContent("Build") {
                    let display = BuildInfo.commitHash == "dev" ? "Development" : String(BuildInfo.commitHash.prefix(7))
                    Text(display)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } header: {
                Label("About", systemImage: "info.circle")
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 620)
    }

    private func notifyChange() {
        onSettingsChanged?(intervalMinutes, idleThreshold, blockingMode, stretchDuration)
    }
}

/// Hosts the SwiftUI PreferencesView in an NSWindow.
final class PreferencesWindowController: NSWindowController {
    convenience init(onSettingsChanged: @escaping (_ intervalMinutes: Int, _ idleThreshold: Double, _ blockingMode: Bool, _ stretchDuration: Int) -> Void) {
        let prefsView = PreferencesView(onSettingsChanged: onSettingsChanged)
        let hostingController = NSHostingController(rootView: prefsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "StandupReminder Preferences"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 420, height: 620))
        window.center()

        self.init(window: window)
    }

    func showWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
