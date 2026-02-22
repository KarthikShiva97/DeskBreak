import SwiftUI

/// SwiftUI view for configuring reminder settings.
struct PreferencesView: View {
    @AppStorage("reminderIntervalMinutes") private var intervalMinutes: Int = 25
    @AppStorage("idleThresholdSeconds") private var idleThreshold: Double = 120
    @AppStorage("blockingModeEnabled") private var blockingMode: Bool = true
    @AppStorage("stretchDurationSeconds") private var stretchDuration: Int = 60

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
                Text("Reminder Settings")
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
                Text("Break Enforcement")
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Snooze: 2 per break (5min, then 2min)")
                    Text("Posture nudge: silent reminder at halfway")
                    Text("Break Now: Cmd+B in the menu bar")
                    Text("Screen sharing: overlay auto-deferred")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } header: {
                Text("How it works")
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 440)
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
        window.setContentSize(NSSize(width: 420, height: 440))
        window.center()

        self.init(window: window)
    }

    func showWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
