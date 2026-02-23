import SwiftUI

// MARK: - Timeline Window Host

struct DailyTimelineView: View {
    let store: DailyTimelineStore
    let totalActiveSeconds: TimeInterval

    /// Refreshes the view periodically so the "now" marker and open segment stay current.
    @State private var now = Date()
    private let refreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headerSection
                summaryCards
                timelineBar
                eventLog
            }
            .padding(24)
        }
        .frame(minWidth: 520, idealWidth: 600, minHeight: 500, idealHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(refreshTimer) { _ in now = Date() }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Today's Timeline")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text(formattedDate)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label("\(store.events.count) events", systemImage: "list.bullet")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.quaternary, in: Capsule())
        }
    }

    // MARK: - Summary Cards

    private var summaryCards: some View {
        let durations = store.durationByKind()
        let workTime = durations[.working, default: 0]
        let idleTime = durations[.idle, default: 0]
        let meetingTime = durations[.inMeeting, default: 0]
        let breaksCompleted = store.count(of: .breakCompleted)
        let breaksSkipped = store.count(of: .breakSkipped)

        return LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12),
        ], spacing: 12) {
            StatCard(title: "Work Time", value: formatDuration(workTime), icon: "desktopcomputer", color: .blue)
            StatCard(title: "Idle Time", value: formatDuration(idleTime), icon: "moon.zzz", color: .gray)
            StatCard(title: "Meetings", value: formatDuration(meetingTime), icon: "video", color: .purple)
            StatCard(title: "Breaks Done", value: "\(breaksCompleted)", icon: "checkmark.circle", color: .green)
            StatCard(title: "Breaks Skipped", value: "\(breaksSkipped)", icon: "forward.end", color: .orange)
            StatCard(title: "Health Alerts", value: "\(store.count(of: .healthWarning))", icon: "exclamationmark.triangle", color: .red)
        }
    }

    // MARK: - Visual Timeline Bar

    private var timelineBar: some View {
        let segments = store.computeSegments()

        return VStack(alignment: .leading, spacing: 8) {
            Text("Activity Timeline")
                .font(.headline)

            if segments.isEmpty {
                Text("No activity recorded yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                TimelineBarView(segments: segments, now: now)
                    .frame(height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                // Time labels
                if let first = segments.first, let last = segments.last {
                    HStack {
                        Text(timeLabel(first.start))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(timeLabel(now > last.end ? now : last.end))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                // Legend
                HStack(spacing: 16) {
                    LegendDot(color: .blue, label: "Working")
                    LegendDot(color: .gray.opacity(0.4), label: "Idle")
                    LegendDot(color: .green, label: "Break")
                    LegendDot(color: .purple, label: "Meeting")
                    LegendDot(color: .orange, label: "Disabled")
                }
                .font(.caption)
                .padding(.top, 4)
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
    }

    // MARK: - Event Log

    private var eventLog: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Event Log")
                .font(.headline)

            if store.events.isEmpty {
                Text("Events will appear here as your day progresses.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                // Show most recent first, capped at 50 to keep the window snappy
                let recentEvents = Array(store.events.suffix(50).reversed())
                ForEach(recentEvents) { event in
                    EventRow(event: event)
                }
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
    }

    // MARK: - Helpers

    private var formattedDate: String {
        let f = DateFormatter()
        f.dateStyle = .full
        return f.string(from: Date())
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int(seconds) / 60
        if totalMinutes >= 60 {
            let h = totalMinutes / 60
            let m = totalMinutes % 60
            return "\(h)h \(m)m"
        }
        return "\(totalMinutes)m"
    }

    private func timeLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }
}

// MARK: - Stat Card

private struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Timeline Bar (the visual colored strip)

private struct TimelineBarView: View {
    let segments: [TimelineSegment]
    let now: Date

    var body: some View {
        GeometryReader { geo in
            let totalSpan = timeSpan
            guard totalSpan > 0 else { return AnyView(EmptyView()) }

            return AnyView(
                ZStack(alignment: .leading) {
                    // Background
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.1))

                    // Segments
                    ForEach(segments) { segment in
                        let startFraction = segment.start.timeIntervalSince(earliestStart) / totalSpan
                        let widthFraction = segment.duration / totalSpan

                        RoundedRectangle(cornerRadius: 2)
                            .fill(color(for: segment.kind))
                            .frame(width: max(2, geo.size.width * widthFraction))
                            .offset(x: geo.size.width * startFraction)
                    }

                    // "Now" marker
                    let nowFraction = now.timeIntervalSince(earliestStart) / totalSpan
                    if nowFraction >= 0 && nowFraction <= 1 {
                        Rectangle()
                            .fill(Color.primary)
                            .frame(width: 2, height: geo.size.height + 8)
                            .offset(x: geo.size.width * nowFraction - 1, y: -4)
                    }
                }
            )
        }
    }

    private var earliestStart: Date {
        segments.first?.start ?? now
    }

    private var timeSpan: TimeInterval {
        guard let first = segments.first else { return 0 }
        let latestEnd = segments.map(\.end).max() ?? now
        let end = max(latestEnd, now)
        return end.timeIntervalSince(first.start)
    }

    private func color(for kind: TimelineSegmentKind) -> Color {
        switch kind {
        case .working:   return .blue
        case .idle:      return .gray.opacity(0.3)
        case .onBreak:   return .green
        case .inMeeting: return .purple
        case .disabled:  return .orange
        }
    }
}

// MARK: - Legend Dot

private struct LegendDot: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
        }
    }
}

// MARK: - Event Row

private struct EventRow: View {
    let event: TimelineEvent

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(iconColor)
                .frame(width: 24, height: 24)
                .background(iconColor.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                if let detail = event.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Text(timeString)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var icon: String {
        switch event.kind {
        case .workStarted:    return "play.circle"
        case .workEnded:      return "pause.circle"
        case .breakCompleted: return "checkmark.circle"
        case .breakSkipped:   return "forward.end"
        case .breakSnoozed:   return "clock.badge.questionmark"
        case .meetingStarted: return "video"
        case .meetingEnded:   return "video.slash"
        case .healthWarning:  return "exclamationmark.triangle"
        case .disabled:       return "pause.rectangle"
        case .resumed:        return "play.rectangle"
        case .sessionReset:   return "arrow.counterclockwise"
        }
    }

    private var iconColor: Color {
        switch event.kind {
        case .workStarted:    return .blue
        case .workEnded:      return .gray
        case .breakCompleted: return .green
        case .breakSkipped:   return .orange
        case .breakSnoozed:   return .yellow
        case .meetingStarted: return .purple
        case .meetingEnded:   return .purple
        case .healthWarning:  return .red
        case .disabled:       return .orange
        case .resumed:        return .blue
        case .sessionReset:   return .gray
        }
    }

    private var label: String {
        switch event.kind {
        case .workStarted:    return "Started working"
        case .workEnded:      return "Went idle"
        case .breakCompleted: return "Break completed"
        case .breakSkipped:   return "Break skipped"
        case .breakSnoozed:   return "Break snoozed"
        case .meetingStarted: return "Meeting started"
        case .meetingEnded:   return "Meeting ended"
        case .healthWarning:  return "Health warning"
        case .disabled:       return "Tracking disabled"
        case .resumed:        return "Tracking resumed"
        case .sessionReset:   return "Session reset"
        }
    }

    private var timeString: String {
        let f = DateFormatter()
        f.dateFormat = "h:mm:ss a"
        return f.string(from: event.timestamp)
    }
}

// MARK: - Window Controller

final class DailyTimelineWindowController: NSWindowController {
    convenience init(store: DailyTimelineStore, totalActiveSeconds: TimeInterval) {
        let view = DailyTimelineView(store: store, totalActiveSeconds: totalActiveSeconds)
        let hostingController = NSHostingController(rootView: view)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Today's Timeline — DeskBreak"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 600, height: 640))
        window.minSize = NSSize(width: 480, height: 400)
        window.center()

        self.init(window: window)
    }

    func showWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
