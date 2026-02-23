import Foundation

// MARK: - Timeline Event Types

/// Every meaningful state change during the workday is recorded as a `TimelineEvent`.
/// Events are append-only; the store never mutates past entries.
enum TimelineEventKind: String, Codable {
    case workStarted        // User became active after idle / app launch
    case workEnded          // User went idle (past idle threshold)
    case breakStarted       // Stretch break overlay appeared
    case breakCompleted     // Stretch break finished (full duration)
    case breakSkipped       // Stretch break dismissed early
    case breakSnoozed       // User snoozed upcoming break
    case meetingStarted     // Meeting app detected
    case meetingEnded       // Meeting app no longer running
    case healthWarning      // Continuous sitting health warning fired
    case disabled           // User disabled tracking
    case resumed            // User resumed tracking
    case sessionReset       // User reset the session
}

/// A single timestamped event in today's timeline.
struct TimelineEvent: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let kind: TimelineEventKind

    /// Optional human-readable detail (e.g., "60 min continuous sitting" for health warnings).
    let detail: String?

    init(kind: TimelineEventKind, detail: String? = nil, timestamp: Date = Date()) {
        self.id = UUID()
        self.timestamp = timestamp
        self.kind = kind
        self.detail = detail
    }
}

// MARK: - Computed Timeline Segments

/// A continuous span of time in a particular state, derived from raw events.
/// Used by the visual timeline to draw colored blocks.
enum TimelineSegmentKind {
    case working
    case idle
    case onBreak
    case inMeeting
    case disabled
}

struct TimelineSegment: Identifiable {
    let id = UUID()
    let kind: TimelineSegmentKind
    let start: Date
    let end: Date

    var duration: TimeInterval { end.timeIntervalSince(start) }
}

// MARK: - Daily Timeline Store

/// Append-only event log for a single calendar day.
///
/// Persistence uses JSON files in Application Support, one per day, so history
/// survives app restarts. Old files are pruned automatically.
final class DailyTimelineStore {
    private(set) var events: [TimelineEvent] = []
    private let dateString: String
    private let fileURL: URL

    /// How many days of history to keep on disk.
    private static let retentionDays = 30

    /// The calendar day this store represents (yyyy-MM-dd).
    var day: String { dateString }

    // MARK: - Init

    init(date: Date = Date()) {
        self.dateString = Self.dateFormatter.string(from: date)
        self.fileURL = Self.storageDirectory.appendingPathComponent("\(dateString).json")
        loadFromDisk()
    }

    /// Testable initializer — accepts a custom file URL for isolation.
    init(dateString: String, fileURL: URL) {
        self.dateString = dateString
        self.fileURL = fileURL
        loadFromDisk()
    }

    // MARK: - Recording

    /// Append a new event. Thread-safe for main-thread callers (all our callers are).
    func record(_ kind: TimelineEventKind, detail: String? = nil) {
        let event = TimelineEvent(kind: kind, detail: detail)
        events.append(event)
        saveToDisk()
    }

    // MARK: - Computed Segments

    /// Derive continuous time segments from raw events for the visual timeline.
    /// Falls back to a single "working" segment from first event to now if events
    /// are sparse.
    func computeSegments() -> [TimelineSegment] {
        guard !events.isEmpty else { return [] }

        var segments: [TimelineSegment] = []
        var currentKind: TimelineSegmentKind = .idle
        var segmentStart: Date = events[0].timestamp

        for event in events {
            let newKind: TimelineSegmentKind? = segmentKind(for: event.kind)

            if let newKind, newKind != currentKind {
                // Close previous segment if it has nonzero duration
                if event.timestamp > segmentStart {
                    segments.append(TimelineSegment(
                        kind: currentKind,
                        start: segmentStart,
                        end: event.timestamp
                    ))
                }
                currentKind = newKind
                segmentStart = event.timestamp
            }
        }

        // Close the final open segment up to "now" (or end of day if viewing history)
        let endTime: Date
        if isToday {
            endTime = Date()
        } else {
            // End of that calendar day
            var components = Calendar.current.dateComponents([.year, .month, .day], from: events[0].timestamp)
            components.hour = 23
            components.minute = 59
            components.second = 59
            endTime = Calendar.current.date(from: components) ?? events.last!.timestamp
        }

        if endTime > segmentStart {
            segments.append(TimelineSegment(
                kind: currentKind,
                start: segmentStart,
                end: endTime
            ))
        }

        return segments
    }

    // MARK: - Summary

    /// Total time spent in each segment kind today.
    func durationByKind() -> [TimelineSegmentKind: TimeInterval] {
        var result: [TimelineSegmentKind: TimeInterval] = [:]
        for segment in computeSegments() {
            result[segment.kind, default: 0] += segment.duration
        }
        return result
    }

    /// Count of events matching the given kind.
    func count(of kind: TimelineEventKind) -> Int {
        events.filter { $0.kind == kind }.count
    }

    // MARK: - Persistence

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static var storageDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("DeskBreak/Timeline")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var isToday: Bool {
        dateString == Self.dateFormatter.string(from: Date())
    }

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            events = try JSONDecoder().decode([TimelineEvent].self, from: data)
        } catch {
            print("[DailyTimeline] Failed to load \(fileURL.lastPathComponent): \(error)")
        }
    }

    private func saveToDisk() {
        do {
            let data = try JSONEncoder().encode(events)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("[DailyTimeline] Failed to save \(fileURL.lastPathComponent): \(error)")
        }
    }

    /// Remove timeline files older than `retentionDays`.
    static func pruneOldFiles() {
        let dir = storageDirectory
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { return }

        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) ?? Date()
        let cutoffString = dateFormatter.string(from: cutoff)

        for file in files where file.hasSuffix(".json") {
            let dayString = file.replacingOccurrences(of: ".json", with: "")
            if dayString < cutoffString {
                try? fm.removeItem(at: dir.appendingPathComponent(file))
            }
        }
    }

    // MARK: - Helpers

    /// Map event kinds to the segment state they transition into.
    /// Returns nil for events that don't change the active segment (e.g. snooze, health warning).
    private func segmentKind(for eventKind: TimelineEventKind) -> TimelineSegmentKind? {
        switch eventKind {
        case .workStarted:      return .working
        case .workEnded:        return .idle
        case .breakStarted:     return .onBreak
        case .breakCompleted:   return .working  // break ended, back to work
        case .breakSkipped:     return .working
        case .meetingStarted:   return .inMeeting
        case .meetingEnded:     return .working
        case .disabled:         return .disabled
        case .resumed:          return .working
        case .sessionReset:     return .idle
        case .breakSnoozed:     return nil
        case .healthWarning:    return nil
        }
    }
}
