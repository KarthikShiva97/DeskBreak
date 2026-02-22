import Cocoa
import SwiftUI

// MARK: - SwiftUI Warning Banner View

struct WarningBannerView: View {
    let secondsUntilBreak: Int
    let canSnooze: Bool
    let onSnooze: () -> Void

    @State private var countdown: Int
    @State private var timer: Timer?
    @State private var opacity: Double = 0

    init(secondsUntilBreak: Int, canSnooze: Bool, onSnooze: @escaping () -> Void) {
        self.secondsUntilBreak = secondsUntilBreak
        self.canSnooze = canSnooze
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

                Text("Finish your thought — your screen will be blocked soon")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if canSnooze {
                Button(action: onSnooze) {
                    Label("Snooze 5m", systemImage: "clock.badge.questionmark")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
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
            startCountdown()
        }
        .onDisappear { timer?.invalidate() }
    }

    private func startCountdown() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            if countdown > 0 {
                withAnimation { countdown -= 1 }
            } else {
                timer?.invalidate()
            }
        }
    }
}

// MARK: - NSWindow controller for the warning banner

final class WarningBannerController {
    private var window: NSWindow?

    func show(secondsUntilBreak: Int, canSnooze: Bool, onSnooze: @escaping () -> Void) {
        dismiss()

        let bannerView = WarningBannerView(
            secondsUntilBreak: secondsUntilBreak,
            canSnooze: canSnooze,
            onSnooze: { [weak self] in
                self?.dismiss()
                onSnooze()
            }
        )

        let hostingView = NSHostingView(rootView: bannerView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 480, height: 70)

        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame

        // Position at top-center of screen
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

        // Play a gentle sound
        NSSound(named: .init("Tink"))?.play()

        window = panel
    }

    func dismiss() {
        if let window {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                window.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                self?.window?.orderOut(nil)
                self?.window = nil
            }
        }
    }
}
