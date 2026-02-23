import Cocoa
import Combine
import SwiftUI

// MARK: - SwiftUI Warning Banner View

struct WarningBannerView: View {
    let secondsUntilBreak: Int
    let canSnooze: Bool
    let snoozeOptions: [Int]
    let snoozesRemaining: Int
    let onSnooze: (Int) -> Void

    @State private var countdown: Int
    @State private var opacity: Double = 0

    private let timerPublisher = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(secondsUntilBreak: Int, canSnooze: Bool, snoozeOptions: [Int], snoozesRemaining: Int, onSnooze: @escaping (Int) -> Void) {
        self.secondsUntilBreak = secondsUntilBreak
        self.canSnooze = canSnooze
        self.snoozeOptions = snoozeOptions
        self.snoozesRemaining = snoozesRemaining
        self.onSnooze = onSnooze
        self._countdown = State(initialValue: secondsUntilBreak)
    }

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "figure.stand")
                .font(.system(size: 24))
                .foregroundStyle(.orange)
                .symbolEffect(.bounce, isActive: true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Stretch break in \(countdown)s")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())

                if canSnooze {
                    Text("\(snoozesRemaining) snooze\(snoozesRemaining == 1 ? "" : "s") left")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Wrap up — stretch break coming up")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if canSnooze {
                HStack(spacing: 6) {
                    ForEach(snoozeOptions, id: \.self) { minutes in
                        Button { onSnooze(minutes) } label: {
                            Text("\(minutes)m")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThickMaterial)
                .shadow(color: .black.opacity(0.2), radius: 20, y: 8)
        }
        .frame(width: 480)
        .opacity(opacity)
        .onAppear {
            withAnimation(.easeOut(duration: 0.5)) { opacity = 1 }
        }
        .onReceive(timerPublisher) { _ in
            if countdown > 1 {
                withAnimation { countdown -= 1 }
            } else {
                // Don't show "0s" — the break overlay is about to appear
                withAnimation(.easeOut(duration: 0.3)) { opacity = 0 }
            }
        }
    }
}

// MARK: - NSWindow controller for the warning banner

final class WarningBannerController {
    private var window: NSWindow?

    func show(secondsUntilBreak: Int, canSnooze: Bool, snoozeOptions: [Int], snoozesRemaining: Int, onSnooze: @escaping (Int) -> Void) {
        dismiss()

        let bannerView = WarningBannerView(
            secondsUntilBreak: secondsUntilBreak,
            canSnooze: canSnooze,
            snoozeOptions: snoozeOptions,
            snoozesRemaining: snoozesRemaining,
            onSnooze: { [weak self] minutes in
                self?.dismiss()
                onSnooze(minutes)
            }
        )

        let hostingView = NSHostingView(rootView: bannerView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 480, height: 70)

        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame

        let x = screenFrame.midX - 240
        let y = screenFrame.maxY - 90
        let windowFrame = NSRect(x: x, y: y, width: 480, height: 70)

        let panel = NSPanel(
            contentRect: windowFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.orderFrontRegardless()

        // Play a gentle system sound (graceful fallback if not found)
        if let sound = NSSound(named: NSSound.Name("Tink")) {
            sound.play()
        } else {
            NSSound.beep()
        }

        window = panel
    }

    func dismiss() {
        guard let w = window else { return }
        window = nil // Immediately clear to prevent double-dismiss race
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            w.animator().alphaValue = 0
        } completionHandler: {
            w.orderOut(nil)
        }
    }
}
