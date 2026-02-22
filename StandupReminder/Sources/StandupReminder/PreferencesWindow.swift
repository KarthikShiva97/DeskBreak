import SwiftUI

/// SwiftUI view for configuring reminder settings.
struct PreferencesView: View {
    @AppStorage("reminderIntervalMinutes") private var intervalMinutes: Int = 30
    @AppStorage("idleThresholdSeconds") private var idleThreshold: Double = 120
    @AppStorage("launchAtLogin") private var launchAtLogin: Bool = false

    /// Called when the user changes settings so the ReminderManager can pick them up.
    var onSettingsChanged: ((_ intervalMinutes: Int, _ idleThreshold: Double) -> Void)?

    private let intervalOptions = [10, 15, 20, 25, 30, 45, 60, 90, 120]
    private let idleOptions: [(label: String, seconds: Double)] = [
        ("1 minute", 60),
        ("2 minutes", 120),
        ("3 minutes", 180),
        ("5 minutes", 300),
        ("10 minutes", 600),
    ]

    var body: some View {
        Form {
            Section {
                Picker("Remind me every:", selection: $intervalMinutes) {
                    ForEach(intervalOptions, id: \.self) { mins in
                        Text("\(mins) minutes").tag(mins)
                    }
                }
                .onChange(of: intervalMinutes) { _, newValue in
                    onSettingsChanged?(newValue, idleThreshold)
                }

                Picker("Consider me idle after:", selection: $idleThreshold) {
                    ForEach(idleOptions, id: \.seconds) { option in
                        Text(option.label).tag(option.seconds)
                    }
                }
                .onChange(of: idleThreshold) { _, newValue in
                    onSettingsChanged?(intervalMinutes, newValue)
                }
            } header: {
                Text("Reminder Settings")
            }

            Section {
                Text("StandupReminder sits in your menu bar and tracks how long you've been actively working (mouse/keyboard activity). When you've been working for the configured interval, it sends a macOS notification reminding you to stand up and stretch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("About")
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 280)
    }
}

/// Hosts the SwiftUI PreferencesView in an NSWindow.
final class PreferencesWindowController: NSWindowController {
    var onSettingsChanged: ((_ intervalMinutes: Int, _ idleThreshold: Double) -> Void)?

    convenience init(onSettingsChanged: @escaping (_ intervalMinutes: Int, _ idleThreshold: Double) -> Void) {
        let prefsView = PreferencesView(onSettingsChanged: onSettingsChanged)
        let hostingController = NSHostingController(rootView: prefsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "StandupReminder Preferences"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 380, height: 280))
        window.center()

        self.init(window: window)
        self.onSettingsChanged = onSettingsChanged
    }

    func showWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
