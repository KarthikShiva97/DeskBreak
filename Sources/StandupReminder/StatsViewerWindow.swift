import SwiftUI

// MARK: - Stats Viewer View

struct StatsViewerView: View {
    enum Tab: String, CaseIterable {
        case today = "Today"
        case daily = "Daily"
        case weekly = "Weekly"
    }

    @State private var selectedTab: Tab = .today
    @State private var selectedDate: Date = Date()
    @State private var weekStartDate: Date = Calendar.current.startOfWeek(for: Date())

    /// Timeline store for the "Today" tab (replaces the old summary-only view).
    let timelineStore: DailyTimelineStore
    let totalActiveSeconds: TimeInterval

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            Divider()

            switch selectedTab {
            case .today:
                DailyTimelineView(
                    store: timelineStore,
                    totalActiveSeconds: totalActiveSeconds
                )
            case .daily:
                DailyStatsView(selectedDate: $selectedDate)
            case .weekly:
                WeeklyStatsView(weekStart: $weekStartDate)
            }
        }
        .frame(minWidth: 520, idealWidth: 600, minHeight: 500, idealHeight: 640)
    }
}

// MARK: - Daily Stats (Calendar Picker)

private struct DailyStatsView: View {
    @Binding var selectedDate: Date

    var body: some View {
        VStack(spacing: 12) {
            DatePicker(
                "Select a date:",
                selection: $selectedDate,
                in: ...Date(),
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .padding(.horizontal)

            Divider()

            let dateString = Self.dateFormatter.string(from: selectedDate)
            if let record = DailyStatsStore.shared.record(for: dateString) {
                ScrollView {
                    StatsGrid(
                        breaksCompleted: record.breaksCompleted,
                        breaksSkipped: record.breaksSkipped,
                        breaksSnoozed: record.breaksSnoozed,
                        healthWarnings: record.healthWarningsReceived,
                        longestSitting: record.longestContinuousSittingSeconds,
                        totalWorkSeconds: record.totalWorkSeconds
                    )
                    .padding()
                }
            } else {
                Spacer()
                Text("No data recorded for this day.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

// MARK: - Weekly Stats

private struct WeeklyStatsView: View {
    @Binding var weekStart: Date

    private var weekEnd: Date {
        Calendar.current.date(byAdding: .day, value: 6, to: weekStart)!
    }

    private var records: [DailyStatsRecord] {
        DailyStatsStore.shared.records(from: weekStart, to: weekEnd)
    }

    var body: some View {
        VStack(spacing: 12) {
            // Week navigation
            HStack {
                Button(action: previousWeek) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)

                Spacer()

                Text(weekRangeLabel)
                    .font(.headline)

                Spacer()

                Button(action: nextWeek) {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderless)
                .disabled(weekEnd >= Calendar.current.startOfDay(for: Date()))
            }
            .padding(.horizontal)
            .padding(.top, 12)

            Divider()

            if records.isEmpty {
                Spacer()
                Text("No data recorded for this week.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        // Aggregated totals
                        let totals = aggregated
                        StatsGrid(
                            breaksCompleted: totals.completed,
                            breaksSkipped: totals.skipped,
                            breaksSnoozed: totals.snoozed,
                            healthWarnings: totals.warnings,
                            longestSitting: totals.longestSitting,
                            totalWorkSeconds: totals.totalWork
                        )

                        Divider()

                        // Daily breakdown bars
                        Text("Daily Breakdown")
                            .font(.subheadline.bold())
                            .frame(maxWidth: .infinity, alignment: .leading)

                        DailyBreakdownChart(weekStart: weekStart, records: records)
                    }
                    .padding()
                }
            }
        }
    }

    private var weekRangeLabel: String {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        let start = f.string(from: weekStart)
        let end = f.string(from: weekEnd)
        return "\(start) – \(end)"
    }

    private var aggregated: (completed: Int, skipped: Int, snoozed: Int, warnings: Int, longestSitting: TimeInterval, totalWork: TimeInterval) {
        var completed = 0, skipped = 0, snoozed = 0, warnings = 0
        var longestSitting: TimeInterval = 0
        var totalWork: TimeInterval = 0
        for r in records {
            completed += r.breaksCompleted
            skipped += r.breaksSkipped
            snoozed += r.breaksSnoozed
            warnings += r.healthWarningsReceived
            longestSitting = max(longestSitting, r.longestContinuousSittingSeconds)
            totalWork += r.totalWorkSeconds
        }
        return (completed, skipped, snoozed, warnings, longestSitting, totalWork)
    }

    private func previousWeek() {
        weekStart = Calendar.current.date(byAdding: .day, value: -7, to: weekStart)!
    }

    private func nextWeek() {
        let next = Calendar.current.date(byAdding: .day, value: 7, to: weekStart)!
        let today = Calendar.current.startOfDay(for: Date())
        if next <= today {
            weekStart = next
        }
    }
}

// MARK: - Daily Breakdown Chart (simple bar view)

private struct DailyBreakdownChart: View {
    let weekStart: Date
    let records: [DailyStatsRecord]

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let labelFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f
    }()

    private var maxBreaks: Int {
        let m = records.map(\.breaksCompleted).max() ?? 1
        return max(m, 1)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(0..<7, id: \.self) { offset in
                let date = Calendar.current.date(byAdding: .day, value: offset, to: weekStart)!
                let key = Self.dayFormatter.string(from: date)
                let record = records.first { $0.date == key }
                let count = record?.breaksCompleted ?? 0
                let label = Self.labelFormatter.string(from: date)

                VStack(spacing: 4) {
                    Text("\(count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(count > 0 ? Color.accentColor : Color.gray.opacity(0.2))
                        .frame(height: max(4, CGFloat(count) / CGFloat(maxBreaks) * 80))

                    Text(label)
                        .font(.caption2)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 120)
    }
}

// MARK: - Reusable Stats Grid (used by Daily and Weekly tabs)

private struct StatsGrid: View {
    let breaksCompleted: Int
    let breaksSkipped: Int
    let breaksSnoozed: Int
    let healthWarnings: Int
    let longestSitting: TimeInterval
    let totalWorkSeconds: TimeInterval

    var body: some View {
        LazyVGrid(columns: [
            GridItem(.flexible()),
            GridItem(.flexible()),
        ], spacing: 12) {
            StatCard(title: "Work Time", value: formatDuration(totalWorkSeconds), icon: "deskclock", color: .blue)
            StatCard(title: "Breaks Taken", value: "\(breaksCompleted)", icon: "figure.stand", color: .green)
            StatCard(title: "Breaks Skipped", value: "\(breaksSkipped)", icon: "forward.fill", color: .orange)
            StatCard(title: "Breaks Snoozed", value: "\(breaksSnoozed)", icon: "clock.arrow.circlepath", color: .yellow)
            StatCard(title: "Longest Sitting", value: formatDuration(longestSitting), icon: "chair.fill", color: .red)
            StatCard(title: "Health Warnings", value: "\(healthWarnings)", icon: "exclamationmark.triangle", color: healthWarnings > 0 ? .red : .gray)
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int(seconds) / 60
        let hours = totalMinutes / 60
        let mins = totalMinutes % 60
        if hours > 0 {
            return "\(hours)h \(mins)m"
        } else {
            return "\(mins)m"
        }
    }
}

private struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)

            Text(value)
                .font(.title3.bold())
                .monospacedDigit()

            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Calendar Helper

extension Calendar {
    func startOfWeek(for date: Date) -> Date {
        let components = dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return self.date(from: components) ?? startOfDay(for: date)
    }
}

// MARK: - Window Controller

final class StatsViewerWindowController: NSWindowController {
    convenience init(store: DailyTimelineStore, totalActiveSeconds: TimeInterval) {
        let view = StatsViewerView(
            timelineStore: store,
            totalActiveSeconds: totalActiveSeconds
        )
        let hostingController = NSHostingController(rootView: view)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "DeskBreak Stats"
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
