import Cocoa
import UserNotifications

/// Checks the GitHub repository for new commits on the main branch,
/// then clones, builds, and installs the updated app automatically.
final class AutoUpdater {

    static let shared = AutoUpdater()

    // GitHub repository details
    private let repoOwner = "KarthikShiva97"
    private let repoName = "DeskBreak"
    private let branch = "main"

    // UserDefaults keys
    private static let lastCommitKey = "autoUpdater_lastCommitSHA"
    private static let enabledKey = "autoUpdater_enabled"

    // Check every 4 hours
    private let checkInterval: TimeInterval = 4 * 60 * 60

    private var checkTimer: Timer?
    private(set) var isUpdating = false

    /// Callback fired when an update starts or finishes so the UI can react.
    var onUpdateStateChanged: ((_ updating: Bool) -> Void)?

    var isAutoUpdateEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: AutoUpdater.enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: AutoUpdater.enabledKey)
            if newValue { startPeriodicChecks() } else { stopPeriodicChecks() }
        }
    }

    /// Tracks the last commit SHA the user has seen/dismissed so background
    /// checks don't repeatedly nag about the same version.
    private var lastCheckedCommit: String? {
        get { UserDefaults.standard.string(forKey: AutoUpdater.lastCommitKey) }
        set { UserDefaults.standard.set(newValue, forKey: AutoUpdater.lastCommitKey) }
    }

    private init() {
        // Default to enabled on first launch
        if UserDefaults.standard.object(forKey: AutoUpdater.enabledKey) == nil {
            UserDefaults.standard.set(true, forKey: AutoUpdater.enabledKey)
        }
    }

    // MARK: - Public API

    /// Begin periodic background update checks.
    func startPeriodicChecks() {
        guard isAutoUpdateEnabled else { return }

        // Check shortly after launch
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            self?.checkForUpdates(userInitiated: false)
        }

        scheduleTimer()
    }

    /// Stop periodic checks.
    func stopPeriodicChecks() {
        checkTimer?.invalidate()
        checkTimer = nil
    }

    /// Manually triggered "Check for Updates" (e.g. from menu item).
    /// The optional `completion` is called on the main thread when the check
    /// finishes so the caller can restore UI state (e.g. re-enable menu items).
    func checkForUpdates(userInitiated: Bool, completion: (() -> Void)? = nil) {
        guard !isUpdating else {
            if userInitiated {
                showAlert(title: "Update In Progress",
                          message: "An update is already being installed.")
            }
            completion?()
            return
        }

        fetchLatestCommit { [weak self] result in
            guard let self else { completion?(); return }

            switch result {
            case .success(let remoteCommit):
                let currentCommit = BuildInfo.commitHash
                let isDev = (currentCommit == "dev")
                let isUpToDate: Bool

                if isDev {
                    // Development build — fall back to lastCheckedCommit tracking
                    if self.lastCheckedCommit == nil {
                        self.lastCheckedCommit = remoteCommit
                        isUpToDate = true
                    } else {
                        isUpToDate = (self.lastCheckedCommit == remoteCommit)
                    }
                } else {
                    isUpToDate = (currentCommit == remoteCommit)
                }

                if isUpToDate {
                    if userInitiated {
                        let display = isDev ? "dev" : String(currentCommit.prefix(7))
                        self.showAlert(
                            title: "DeskBreak Is Up to Date",
                            message: "You're running the latest version.\n\nBuild: \(display)")
                    }
                    completion?()
                } else {
                    // For background checks, skip if the user already dismissed this version.
                    if !userInitiated && self.lastCheckedCommit == remoteCommit {
                        completion?()
                        return
                    }
                    self.promptForUpdate(toCommit: remoteCommit, userInitiated: userInitiated, completion: completion)
                }

            case .failure(let error):
                print("[AutoUpdater] Check failed: \(error)")
                if userInitiated {
                    self.showAlert(
                        title: "Update Check Failed",
                        message: "Could not reach GitHub.\n\n\(error.localizedDescription)",
                        style: .warning)
                }
                completion?()
            }
        }
    }

    // MARK: - GitHub API

    private func fetchLatestCommit(completion: @escaping (Result<String, Error>) -> Void) {
        let urlString = "https://api.github.com/repos/\(repoOwner)/\(repoName)/commits/\(branch)"
        guard let url = URL(string: urlString) else {
            completion(.failure(makeError("Invalid GitHub API URL")))
            return
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }

            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard statusCode == 200 else {
                DispatchQueue.main.async {
                    completion(.failure(self.makeError("GitHub API returned HTTP \(statusCode)")))
                }
                return
            }

            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sha = json["sha"] as? String else {
                DispatchQueue.main.async {
                    completion(.failure(self.makeError("Could not parse GitHub response")))
                }
                return
            }

            DispatchQueue.main.async { completion(.success(sha)) }
        }.resume()
    }

    // MARK: - Update Flow

    /// Shows a confirmation dialog and starts the update if the user agrees.
    private func promptForUpdate(toCommit commit: String, userInitiated: Bool, completion: (() -> Void)? = nil) {
        let currentDisplay: String
        if BuildInfo.commitHash == "dev" {
            currentDisplay = "dev"
        } else {
            currentDisplay = String(BuildInfo.commitHash.prefix(7))
        }
        let remoteDisplay = String(commit.prefix(7))

        let alert = NSAlert()
        alert.messageText = "Update Available"
        alert.informativeText = """
            A new version of DeskBreak is available.

            Current build: \(currentDisplay)
            Latest: \(remoteDisplay)

            The app will download, rebuild, and relaunch automatically.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Update Now")
        alert.addButton(withTitle: "Not Now")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            performUpdate(toCommit: commit)
        } else {
            // Remember this version so background checks don't nag.
            self.lastCheckedCommit = commit
        }
        completion?()
    }

    private func performUpdate(toCommit commit: String) {
        isUpdating = true
        onUpdateStateChanged?(true)
        showNotification(title: "Updating DeskBreak",
                         body: "Downloading and building the latest version…")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let fm = FileManager.default
            let tempDir = fm.temporaryDirectory
                .appendingPathComponent("DeskBreak-update-\(UUID().uuidString)")

            defer {
                try? fm.removeItem(at: tempDir)
                DispatchQueue.main.async {
                    self.isUpdating = false
                    self.onUpdateStateChanged?(false)
                }
            }

            do {
                // 1. Shallow-clone the repo
                try self.run("/usr/bin/git", arguments: [
                    "clone", "--depth", "1", "--branch", self.branch,
                    "https://github.com/\(self.repoOwner)/\(self.repoName).git",
                    tempDir.path
                ])

                // 2. Inject build metadata so the new binary knows its commit
                let buildInfoPath = tempDir
                    .appendingPathComponent("Sources/StandupReminderLib/BuildInfo.swift")
                let buildInfoContent = """
                    /// Build metadata — auto-generated during update. Do not edit.
                    enum BuildInfo {
                        static let commitHash = "\(commit)"
                    }

                    """
                try buildInfoContent.write(to: buildInfoPath, atomically: true, encoding: .utf8)

                // 3. Build release binary
                try self.run("/usr/bin/swift", arguments: ["build", "-c", "release"],
                             workingDirectory: tempDir.path)

                // 4. Assemble app bundle in temp dir
                let appBundle = tempDir.appendingPathComponent("StandupReminder.app")
                let macOS = appBundle.appendingPathComponent("Contents/MacOS")
                try fm.createDirectory(at: macOS, withIntermediateDirectories: true)

                let binary = tempDir.appendingPathComponent(".build/release/StandupReminder")
                try fm.copyItem(at: binary, to: macOS.appendingPathComponent("StandupReminder"))

                let plistSrc = tempDir.appendingPathComponent("Resources/Info.plist")
                let plistDst = appBundle.appendingPathComponent("Contents/Info.plist")
                try fm.copyItem(at: plistSrc, to: plistDst)

                // 5. Replace the installed app
                let installedApp = "/Applications/StandupReminder.app"
                if fm.fileExists(atPath: installedApp) {
                    try fm.removeItem(atPath: installedApp)
                }
                try fm.copyItem(at: appBundle, to: URL(fileURLWithPath: installedApp))

                // 6. Record the new commit
                DispatchQueue.main.async {
                    self.lastCheckedCommit = commit
                    self.showNotification(title: "Update Complete",
                                          body: "DeskBreak has been updated. Relaunching…")

                    // 7. Relaunch after a short delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        self.relaunch()
                    }
                }
            } catch {
                print("[AutoUpdater] Update failed: \(error)")
                DispatchQueue.main.async {
                    self.showAlert(
                        title: "Update Failed",
                        message: "The update could not be installed.\n\n\(error.localizedDescription)",
                        style: .critical)
                }
            }
        }
    }

    // MARK: - Helpers

    @discardableResult
    private func run(_ executable: String, arguments: [String],
                     workingDirectory: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let wd = workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: wd)
        }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()

        // Read pipes BEFORE waitUntilExit to avoid deadlock: if the
        // subprocess fills the pipe buffer (~64 KB) it blocks until
        // someone drains the pipe, but waitUntilExit blocks until the
        // process exits — a classic deadlock for large build output.
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()

        process.waitUntilExit()

        let outStr = String(data: outData, encoding: .utf8) ?? ""
        let errStr = String(data: errData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw makeError("Process \(executable) exited with code \(process.terminationStatus): \(errStr)")
        }

        return outStr
    }

    private func relaunch() {
        let appPath = "/Applications/StandupReminder.app"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [appPath]
        try? process.run()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.terminate(nil)
        }
    }

    private func scheduleTimer() {
        checkTimer?.invalidate()
        checkTimer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            self?.checkForUpdates(userInitiated: false)
        }
    }

    /// Shows a modal alert dialog. Used for user-initiated checks where
    /// the feedback must be immediately visible and impossible to miss.
    private func showAlert(title: String, message: String, style: NSAlert.Style = .informational) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Shows a system notification. Used for background events (update progress,
    /// completion) where a non-blocking notification is appropriate.
    private func showNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body

        let request = UNNotificationRequest(
            identifier: "auto-updater-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func makeError(_ message: String) -> NSError {
        NSError(domain: "com.standupreminder.autoupdater", code: -1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
