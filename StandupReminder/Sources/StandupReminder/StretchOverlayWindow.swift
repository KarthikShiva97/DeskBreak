import Cocoa
import SwiftUI

// MARK: - Stretch exercises shown during the break

struct StretchExercise {
    let name: String
    let symbol: String // SF Symbol name
    let instruction: String
}

private let exercises: [StretchExercise] = [
    StretchExercise(name: "Neck Roll", symbol: "figure.cooldown", instruction: "Slowly roll your head in a circle. 5 times each direction."),
    StretchExercise(name: "Shoulder Shrug", symbol: "figure.arms.open", instruction: "Raise both shoulders to your ears, hold 3 seconds, release. Repeat 5 times."),
    StretchExercise(name: "Standing Stretch", symbol: "figure.stand", instruction: "Stand up, reach both arms overhead, and stretch tall. Hold for 10 seconds."),
    StretchExercise(name: "Wrist Circles", symbol: "hand.raised.fingers.spread", instruction: "Extend your arms and rotate your wrists in circles. 10 times each direction."),
    StretchExercise(name: "Spinal Twist", symbol: "figure.flexibility", instruction: "Sit upright, twist your torso to the left, hold 10s. Repeat on the right."),
    StretchExercise(name: "Eye Break", symbol: "eye", instruction: "Look at something 20 feet away for 20 seconds. Blink slowly."),
    StretchExercise(name: "Leg Stretch", symbol: "figure.walk", instruction: "Stand up and do 10 calf raises, then walk around for a moment."),
    StretchExercise(name: "Deep Breathing", symbol: "wind", instruction: "Inhale deeply for 4 seconds, hold for 4, exhale for 6. Repeat 5 times."),
]

// MARK: - SwiftUI Overlay View

struct StretchOverlayView: View {
    let stretchDurationSeconds: Int
    let onComplete: () -> Void

    @State private var secondsRemaining: Int
    @State private var currentExercise: StretchExercise
    @State private var timer: Timer?
    @State private var skipEnabled = false

    init(stretchDurationSeconds: Int, onComplete: @escaping () -> Void) {
        self.stretchDurationSeconds = stretchDurationSeconds
        self.onComplete = onComplete
        self._secondsRemaining = State(initialValue: stretchDurationSeconds)
        self._currentExercise = State(initialValue: exercises.randomElement()!)
    }

    var body: some View {
        ZStack {
            // Dimmed background
            Color.black.opacity(0.88)

            VStack(spacing: 32) {
                Spacer()

                // Title
                Text("Time to Stretch!")
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                // Exercise card
                VStack(spacing: 16) {
                    Image(systemName: currentExercise.symbol)
                        .font(.system(size: 64))
                        .foregroundStyle(.cyan)
                        .symbolEffect(.pulse, isActive: true)

                    Text(currentExercise.name)
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)

                    Text(currentExercise.instruction)
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 500)
                }
                .padding(40)
                .background(.ultraThinMaterial.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 20))

                // Countdown
                Text(formattedTime)
                    .font(.system(size: 72, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())

                // Progress ring
                ZStack {
                    Circle()
                        .stroke(.white.opacity(0.2), lineWidth: 8)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(.cyan, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 1), value: progress)
                }
                .frame(width: 120, height: 120)

                // Skip button (appears after 10 seconds)
                if skipEnabled {
                    Button(action: complete) {
                        Text("I've stretched — let me back in")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(.white.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else {
                    Text("Skip available in \(max(0, 10 - (stretchDurationSeconds - secondsRemaining)))s")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.4))
                }

                Spacer()
            }
            .padding()
        }
        .ignoresSafeArea()
        .onAppear(perform: startTimer)
        .onDisappear { timer?.invalidate() }
    }

    private var progress: Double {
        guard stretchDurationSeconds > 0 else { return 1 }
        return 1.0 - (Double(secondsRemaining) / Double(stretchDurationSeconds))
    }

    private var formattedTime: String {
        let m = secondsRemaining / 60
        let s = secondsRemaining % 60
        return String(format: "%d:%02d", m, s)
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            if secondsRemaining > 0 {
                secondsRemaining -= 1

                // Rotate exercise every 20 seconds
                let elapsed = stretchDurationSeconds - secondsRemaining
                if elapsed > 0 && elapsed % 20 == 0 {
                    withAnimation {
                        currentExercise = exercises.randomElement()!
                    }
                }

                // Enable skip after 10 seconds
                if elapsed >= 10 && !skipEnabled {
                    withAnimation {
                        skipEnabled = true
                    }
                }
            } else {
                complete()
            }
        }
    }

    private func complete() {
        timer?.invalidate()
        timer = nil
        onComplete()
    }
}

// MARK: - NSWindow wrapper for the full-screen overlay

final class StretchOverlayWindowController {
    private var windows: [NSWindow] = []

    /// Shows a full-screen blocking overlay on every screen.
    func show(stretchDurationSeconds: Int, onComplete: @escaping () -> Void) {
        // Dismiss any existing overlay first
        dismiss()

        var completeCalled = false
        let safeComplete: () -> Void = {
            guard !completeCalled else { return }
            completeCalled = true
            DispatchQueue.main.async { [weak self] in
                self?.dismiss()
                onComplete()
            }
        }

        for screen in NSScreen.screens {
            let overlayView = StretchOverlayView(
                stretchDurationSeconds: stretchDurationSeconds,
                onComplete: safeComplete
            )

            let hostingView = NSHostingView(rootView: overlayView)
            hostingView.frame = screen.frame

            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.contentView = hostingView
            window.level = .screenSaver // Above almost everything
            window.isOpaque = false
            window.backgroundColor = .clear
            window.ignoresMouseEvents = false
            window.acceptsMouseMovedEvents = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.makeKeyAndOrderFront(nil)

            windows.append(window)
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss() {
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
    }
}
