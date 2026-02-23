import Foundation

/// A single day's aggregated statistics, persisted to disk.
struct DailyStatsRecord: Codable, Identifiable {
    var id: String { date }

    /// Date string in "yyyy-MM-dd" format.
    let date: String
    var breaksCompleted: Int = 0
    var breaksSkipped: Int = 0
    var breaksSnoozed: Int = 0
    var healthWarningsReceived: Int = 0
    var longestContinuousSittingSeconds: TimeInterval = 0
    var totalWorkSeconds: TimeInterval = 0
}

/// Persists daily stats to a JSON file in Application Support.
/// Thread-safe via a serial queue.
final class DailyStatsStore {
    static let shared = DailyStatsStore()

    private let queue = DispatchQueue(label: "com.standupreminder.dailystats")
    private var cache: [String: DailyStatsRecord] = [:]
    private var dirty = false

    private let fileURL: URL

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("StandupReminder", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        fileURL = appDir.appendingPathComponent("daily-stats.json")
        loadFromDisk()
    }

    // MARK: - Public API

    /// Returns the record for a given date string ("yyyy-MM-dd"), or nil if none exists.
    func record(for dateString: String) -> DailyStatsRecord? {
        queue.sync { cache[dateString] }
    }

    /// Returns the record for today, creating one if needed.
    func todayRecord() -> DailyStatsRecord {
        let today = Self.dateFormatter.string(from: Date())
        return queue.sync {
            cache[today] ?? DailyStatsRecord(date: today)
        }
    }

    /// Returns records for a date range (inclusive).
    func records(from startDate: Date, to endDate: Date) -> [DailyStatsRecord] {
        let calendar = Calendar.current
        var results: [DailyStatsRecord] = []
        var current = calendar.startOfDay(for: startDate)
        let end = calendar.startOfDay(for: endDate)

        while current <= end {
            let key = Self.dateFormatter.string(from: current)
            if let record = queue.sync(execute: { cache[key] }) {
                results.append(record)
            }
            current = calendar.date(byAdding: .day, value: 1, to: current)!
        }
        return results
    }

    /// Returns all stored records sorted by date.
    func allRecords() -> [DailyStatsRecord] {
        queue.sync {
            cache.values.sorted { $0.date < $1.date }
        }
    }

    /// Record a completed break for today.
    func recordBreakCompleted() {
        mutateToday { $0.breaksCompleted += 1 }
    }

    /// Record a skipped break for today.
    func recordBreakSkipped() {
        mutateToday { $0.breaksSkipped += 1 }
    }

    /// Record a snoozed break for today.
    func recordBreakSnoozed() {
        mutateToday { $0.breaksSnoozed += 1 }
    }

    /// Record a health warning for today.
    func recordHealthWarning() {
        mutateToday { $0.healthWarningsReceived += 1 }
    }

    /// Update longest continuous sitting if the new value is higher.
    func updateLongestContinuousSitting(_ seconds: TimeInterval) {
        mutateToday { record in
            if seconds > record.longestContinuousSittingSeconds {
                record.longestContinuousSittingSeconds = seconds
            }
        }
    }

    /// Update total work seconds for today.
    func updateTotalWorkSeconds(_ seconds: TimeInterval) {
        mutateToday { $0.totalWorkSeconds = seconds }
    }

    /// Seed today's record with absolute values restored from another source
    /// (e.g. timeline). Used when DailyStatsStore has no data for today but
    /// the timeline does — keeps the two stores in sync going forward.
    func seedToday(
        breaksCompleted: Int,
        breaksSkipped: Int,
        breaksSnoozed: Int,
        healthWarnings: Int,
        totalWorkSeconds: TimeInterval
    ) {
        mutateToday { record in
            record.breaksCompleted = breaksCompleted
            record.breaksSkipped = breaksSkipped
            record.breaksSnoozed = breaksSnoozed
            record.healthWarningsReceived = healthWarnings
            record.totalWorkSeconds = totalWorkSeconds
        }
    }

    /// Flush any pending changes to disk immediately.
    func flush() {
        queue.sync {
            if dirty {
                saveToDisk()
            }
        }
    }

    // MARK: - Internals

    private func mutateToday(_ mutation: (inout DailyStatsRecord) -> Void) {
        let today = Self.dateFormatter.string(from: Date())
        queue.sync {
            var record = cache[today] ?? DailyStatsRecord(date: today)
            mutation(&record)
            cache[today] = record
            dirty = true
        }
        scheduleSave()
    }

    private var saveWorkItem: DispatchWorkItem?

    /// Debounce disk writes — save at most once per second.
    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            // Already executing on `queue`, so call saveToDisk directly.
            self?.saveToDisk()
        }
        saveWorkItem = item
        queue.asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let records = try JSONDecoder().decode([DailyStatsRecord].self, from: data)
            for record in records {
                cache[record.date] = record
            }
        } catch {
            print("DailyStatsStore: failed to load stats: \(error)")
        }
    }

    /// Must be called on `queue`.
    private func saveToDisk() {
        do {
            let records = Array(cache.values).sorted { $0.date < $1.date }
            let data = try JSONEncoder().encode(records)
            try data.write(to: fileURL, options: .atomic)
            dirty = false
        } catch {
            print("DailyStatsStore: failed to save stats: \(error)")
        }
    }
}
