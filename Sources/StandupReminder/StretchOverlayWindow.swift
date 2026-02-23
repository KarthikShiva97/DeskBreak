import Cocoa
import Combine
import SwiftUI

// MARK: - Stretch exercises shown during the break

struct StretchExercise {
    let name: String
    let symbol: String // SF Symbol name
    let instruction: String
}

// Exercises targeted for disc bulge / lower back relief.
// Prioritizes standing extensions and decompression over seated twists.
private let exercises: [StretchExercise] = [
    StretchExercise(name: "Standing Back Extension", symbol: "figure.stand", instruction: "Stand up. Place hands on lower back, gently lean backwards. Hold 5 seconds. Repeat 5 times. This is the single most important move for disc bulges."),
    StretchExercise(name: "McKenzie Press-Up", symbol: "figure.cooldown", instruction: "Lie face down. Place palms flat at shoulder level. Press up, extending your back while keeping hips on the floor. Hold 10 seconds. Repeat 5 times."),
    StretchExercise(name: "Cat-Cow", symbol: "figure.flexibility", instruction: "On hands and knees: arch your back up (cat), then let your belly drop and look up (cow). Slow and controlled. 8 reps."),
    StretchExercise(name: "Walk It Out", symbol: "figure.walk", instruction: "Walk around your space for 60 seconds. Walking gently decompresses spinal discs. Keep upright posture."),
    StretchExercise(name: "Nerve Glide", symbol: "figure.arms.open", instruction: "Stand tall. Extend one leg forward, heel down, toes up. Gently lean forward with a straight back until you feel a stretch behind the leg. Hold 10s each side."),
    StretchExercise(name: "Hip Flexor Stretch", symbol: "figure.stand", instruction: "Step one foot forward into a lunge. Keep back straight, gently push hips forward. Sitting all day tightens hip flexors which pulls on your spine. Hold 15s each side."),
    StretchExercise(name: "Supported Squat", symbol: "figure.stand", instruction: "Hold onto your desk edge. Squat down slowly, letting your spine decompress. Keep heels flat. Hold 15 seconds."),
    StretchExercise(name: "Deep Breathing", symbol: "wind", instruction: "Stand or lie down. Breathe into your belly: inhale 4 seconds, hold 4, exhale 6. This relaxes the muscles guarding your spine. 5 rounds."),
    StretchExercise(name: "Chin Tuck", symbol: "figure.cooldown", instruction: "Sit or stand tall. Pull your chin straight back (make a double chin). Hold 5 seconds. Repeat 8 times. Corrects forward head posture from screen work."),
    StretchExercise(name: "Prone Lying", symbol: "figure.cooldown", instruction: "Lie face down flat on the floor for 30-60 seconds. Just breathe. This passively extends the spine and takes pressure off the disc."),
]

// MARK: - SwiftUI Overlay View

struct StretchOverlayView: View {
    let stretchDurationSeconds: Int
    let checkIdleTime: (() -> TimeInterval)?
    let onSittingDetected: (() -> Void)?
    let onComplete: (_ wasSkipped: Bool) -> Void

    @State private var secondsRemaining: Int
    @State private var currentExercise: StretchExercise
    @State private var skipEnabled = false
    @State private var overlayOpacity: Double = 0
    @State private var contentScale: Double = 0.9
    @State private var breathingScale: Double = 1.0
    @State private var showCompletion = false
    @State private var completed = false

    // Sitting detection state
    @State private var showSittingNudge = false
    @State private var consecutiveActiveChecks = 0
    @State private var sittingAlreadyReported = false

    // Use Combine timer instead of Timer.scheduledTimer for SwiftUI safety
    private let timerPublisher = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(stretchDurationSeconds: Int, checkIdleTime: (() -> TimeInterval)? = nil, onSittingDetected: (() -> Void)? = nil, onComplete: @escaping (_ wasSkipped: Bool) -> Void) {
        self.stretchDurationSeconds = stretchDurationSeconds
        self.checkIdleTime = checkIdleTime
        self.onSittingDetected = onSittingDetected
        self.onComplete = onComplete
        self._secondsRemaining = State(initialValue: stretchDurationSeconds)
        // Safe default fallback instead of force unwrap
        self._currentExercise = State(initialValue: exercises.first ?? StretchExercise(name: "Stretch", symbol: "figure.stand", instruction: "Stand up and stretch."))
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.05, blue: 0.15),
                    Color(red: 0.10, green: 0.05, blue: 0.20)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if showCompletion {
                completionView
                    .transition(.opacity.combined(with: .scale))
            } else {
                mainContent
                    .scaleEffect(contentScale)
                    .opacity(overlayOpacity)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeOut(duration: 0.6)) {
                overlayOpacity = 1
                contentScale = 1.0
            }
            withAnimation(.easeInOut(duration: 4).repeatForever(autoreverses: true)) {
                breathingScale = 1.08
            }
        }
        .onReceive(timerPublisher) { _ in
            guard !completed else { return }
            tickCountdown()
        }
    }

    // MARK: - Main stretch content

    private var mainContent: some View {
        VStack(spacing: 32) {
            Spacer()

            Text("Time to Stretch!")
                .font(.system(size: 48, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .scaleEffect(breathingScale)

            if showSittingNudge {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.yellow)
                    Text("Still at your desk? Stand up and step back!")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(.orange.opacity(0.25))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

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

            Text(formattedTime)
                .font(.system(size: 72, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .contentTransition(.numericText())

            ZStack {
                Circle()
                    .stroke(.white.opacity(0.2), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        .linearGradient(
                            colors: [.cyan, .blue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: progress)
                    .shadow(color: .cyan.opacity(0.5), radius: 6)
            }
            .frame(width: 120, height: 120)

            if skipEnabled {
                Button(action: { complete(skipped: true) }) {
                    Text("Done Stretching")
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
                let elapsed = stretchDurationSeconds - secondsRemaining
                let skipIn = max(0, 10 - elapsed)
                Text("Skip available in \(skipIn)s")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.4))
            }

            Spacer()
        }
        .padding()
    }

    // MARK: - Completion celebration

    private var completionView: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, isActive: true)

            Text("Great job!")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text("Your spine thanks you")
                .font(.system(size: 18))
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    // MARK: - Helpers

    private var progress: Double {
        guard stretchDurationSeconds > 0 else { return 1 }
        return 1.0 - (Double(secondsRemaining) / Double(stretchDurationSeconds))
    }

    private var formattedTime: String {
        let m = secondsRemaining / 60
        let s = secondsRemaining % 60
        return String(format: "%d:%02d", m, s)
    }

    private func tickCountdown() {
        if secondsRemaining > 0 {
            secondsRemaining -= 1

            let elapsed = stretchDurationSeconds - secondsRemaining
            if elapsed > 0 && elapsed % 20 == 0 {
                withAnimation(.spring(duration: 0.5)) {
                    let others = exercises.filter { $0.name != currentExercise.name }
                    if let next = others.randomElement() {
                        currentExercise = next
                    }
                }
            }

            if elapsed >= 10 && !skipEnabled {
                withAnimation(.spring(duration: 0.4)) {
                    skipEnabled = true
                }
            }

            // Sitting detection: after 15s grace period, check every 5s
            if elapsed >= 15 && elapsed % 5 == 0, let checkIdleTime {
                let idle = checkIdleTime()
                if idle < 3 {
                    consecutiveActiveChecks += 1
                    if consecutiveActiveChecks >= 2 && !showSittingNudge {
                        withAnimation(.spring(duration: 0.5)) {
                            showSittingNudge = true
                        }
                        if !sittingAlreadyReported {
                            sittingAlreadyReported = true
                            onSittingDetected?()
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                            withAnimation(.easeOut(duration: 0.5)) {
                                showSittingNudge = false
                            }
                        }
                    }
                } else {
                    consecutiveActiveChecks = 0
                }
            }
        } else {
            complete(skipped: false)
        }
    }

    private func complete(skipped: Bool) {
        guard !completed else { return }
        completed = true

        if !skipped {
            withAnimation(.spring(duration: 0.5)) {
                showCompletion = true
            }
            // Use main RunLoop timer for the delayed dismiss — safe because
            // the view is still alive (overlay window keeps it retained).
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [onComplete] in
                onComplete(false)
            }
        } else {
            onComplete(true)
        }
    }
}

// MARK: - NSWindow wrapper for the full-screen overlay

final class StretchOverlayWindowController {
    private var windows: [NSWindow] = []
    private var generation: Int = 0

    func show(stretchDurationSeconds: Int, checkIdleTime: (() -> TimeInterval)? = nil, onSittingDetected: (() -> Void)? = nil, onComplete: @escaping (_ wasSkipped: Bool) -> Void) {
        dismiss()

        generation += 1
        let expectedGeneration = generation
        var completeCalled = false
        let safeComplete: (_ wasSkipped: Bool) -> Void = { skipped in
            guard !completeCalled else { return }
            completeCalled = true
            DispatchQueue.main.async { [weak self] in
                // If show() was called again, this closure belongs to the old overlay — bail
                guard let self, self.generation == expectedGeneration else { return }
                self.animateDismiss {
                    onComplete(skipped)
                }
            }
        }

        for screen in NSScreen.screens {
            let overlayView = StretchOverlayView(
                stretchDurationSeconds: stretchDurationSeconds,
                checkIdleTime: checkIdleTime,
                onSittingDetected: onSittingDetected,
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
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.ignoresMouseEvents = false
            window.acceptsMouseMovedEvents = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            window.alphaValue = 0
            window.makeKeyAndOrderFront(nil)

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.5
                window.animator().alphaValue = 1
            }

            windows.append(window)
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    private func animateDismiss(completion: @escaping () -> Void) {
        guard !windows.isEmpty else {
            completion()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.4
            for window in windows {
                window.animator().alphaValue = 0
            }
        }, completionHandler: { [weak self] in
            self?.dismiss()
            completion()
        })
    }

    func dismiss() {
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
    }
}
