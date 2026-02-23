import AVFoundation
import Cocoa
import Vision

/// Periodically captures a frame from the built-in camera and uses Vision's
/// body pose detection to determine whether the user is slouching.
///
/// Detection strategy (front-facing camera):
/// 1. Calibrate "good posture" baseline from a few initial frames
/// 2. Compare current pose against baseline every `checkInterval` seconds
/// 3. Bad posture signals: nose drops relative to shoulders, ear-shoulder
///    vertical gap shrinks (forward lean), shoulder width narrows (rounding)
///
/// Privacy-conscious: the camera runs only during brief capture bursts,
/// NOT continuous video. No images are stored or transmitted.
final class PostureMonitor {

    // MARK: - Configuration

    /// How often to sample a frame for posture analysis (seconds).
    var checkInterval: TimeInterval = 30

    /// How many consecutive bad-posture frames before firing a nudge.
    var badFramesThreshold: Int = 2

    /// Sensitivity: how far posture metrics can deviate from baseline before
    /// being flagged. Lower = more sensitive. Range 0.05–0.30 recommended.
    var sensitivity: Double = 0.15

    // MARK: - Callbacks

    /// Fired when sustained bad posture is detected.
    var onBadPostureDetected: (() -> Void)?

    /// Fired when posture returns to acceptable after a bad-posture nudge.
    var onPostureCorrected: (() -> Void)?

    // MARK: - State

    private(set) var isRunning = false
    private(set) var isCalibrated = false
    private(set) var cameraAuthorized = false

    /// Number of consecutive frames flagged as bad posture.
    private var consecutiveBadFrames: Int = 0

    /// Whether we already fired a nudge for the current bad-posture streak
    /// (don't spam the user — one nudge per streak).
    private var nudgeFiredForCurrentStreak = false

    // MARK: - Baseline (calibration)

    /// Ratio: vertical distance from nose to shoulder midpoint / shoulder width.
    private var baselineNoseShoulderRatio: Double = 0

    /// Ratio: vertical distance from ear midpoint to shoulder midpoint / shoulder width.
    private var baselineEarShoulderRatio: Double = 0

    /// Shoulder width in normalized coordinates (for detecting rounding).
    private var baselineShoulderWidth: Double = 0

    /// Number of calibration samples collected.
    private var calibrationSamples: Int = 0
    private static let calibrationSamplesNeeded = 3

    /// Accumulates calibration values before averaging.
    private var calNoseRatioSum: Double = 0
    private var calEarRatioSum: Double = 0
    private var calShoulderWidthSum: Double = 0

    // MARK: - AVFoundation

    private var captureSession: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private let captureQueue = DispatchQueue(label: "com.standupreminder.posture.capture", qos: .utility)
    private var checkTimer: Timer?

    /// Whether a capture is currently in progress (prevent overlapping captures).
    private var captureInFlight = false

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }

        requestCameraAccess { [weak self] granted in
            guard let self, granted else { return }
            DispatchQueue.main.async {
                self.cameraAuthorized = true
                self.setupCaptureSession()
                self.startTimer()
                self.isRunning = true
            }
        }
    }

    func stop() {
        isRunning = false
        checkTimer?.invalidate()
        checkTimer = nil
        tearDownCaptureSession()
    }

    /// Resets calibration so the next frames become the new baseline.
    func recalibrate() {
        isCalibrated = false
        calibrationSamples = 0
        calNoseRatioSum = 0
        calEarRatioSum = 0
        calShoulderWidthSum = 0
        consecutiveBadFrames = 0
        nudgeFiredForCurrentStreak = false
    }

    // MARK: - Camera access

    private func requestCameraAccess(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                completion(granted)
            }
        default:
            completion(false)
        }
    }

    // MARK: - Capture session

    private func setupCaptureSession() {
        let session = AVCaptureSession()
        session.sessionPreset = .low // We only need a tiny frame for pose detection

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
                ?? AVCaptureDevice.default(for: .video) else {
            print("[PostureMonitor] No camera found")
            return
        }

        guard let input = try? AVCaptureDeviceInput(device: device) else {
            print("[PostureMonitor] Failed to create camera input")
            return
        }

        if session.canAddInput(input) {
            session.addInput(input)
        }

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]

        if session.canAddOutput(output) {
            session.addOutput(output)
        }

        captureSession = session
        videoOutput = output
    }

    private func tearDownCaptureSession() {
        captureSession?.stopRunning()
        captureSession = nil
        videoOutput = nil
    }

    // MARK: - Periodic check

    private func startTimer() {
        checkTimer?.invalidate()
        checkTimer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            self?.captureAndAnalyze()
        }
        // Also capture immediately for calibration
        captureAndAnalyze()
    }

    /// Briefly starts the camera, grabs one frame, analyzes it, then stops the camera.
    private func captureAndAnalyze() {
        guard !captureInFlight, let session = captureSession, let output = videoOutput else { return }
        captureInFlight = true

        captureQueue.async { [weak self] in
            guard let self else { return }

            // Set a one-shot delegate to grab the next frame
            let frameGrabber = FrameGrabber { [weak self] pixelBuffer in
                self?.analyzeFrame(pixelBuffer)
                self?.captureQueue.async {
                    session.stopRunning()
                    DispatchQueue.main.async {
                        self?.captureInFlight = false
                    }
                }
            }
            output.setSampleBufferDelegate(frameGrabber, queue: self.captureQueue)

            // Keep a strong reference until the frame is grabbed
            objc_setAssociatedObject(output, "frameGrabber", frameGrabber, .OBJC_ASSOCIATION_RETAIN)

            session.startRunning()

            // Safety timeout: if no frame arrives in 5 seconds, stop waiting
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.captureInFlight else { return }
                self.captureInFlight = false
                session.stopRunning()
            }
        }
    }

    // MARK: - Vision analysis

    private func analyzeFrame(_ pixelBuffer: CVPixelBuffer) {
        let request = VNDetectHumanBodyPoseRequest()

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        do {
            try handler.perform([request])
        } catch {
            print("[PostureMonitor] Vision request failed: \(error.localizedDescription)")
            return
        }

        guard let observation = request.results?.first else {
            // No person detected — skip this frame
            return
        }

        guard let metrics = extractMetrics(from: observation) else { return }

        if !isCalibrated {
            addCalibrationSample(metrics)
        } else {
            evaluatePosture(metrics)
        }
    }

    // MARK: - Metric extraction

    private struct PoseMetrics {
        /// Vertical distance from nose to shoulder midpoint, normalized by shoulder width.
        let noseShoulderRatio: Double
        /// Vertical distance from ear midpoint to shoulder midpoint, normalized by shoulder width.
        let earShoulderRatio: Double
        /// Shoulder width in normalized image coordinates.
        let shoulderWidth: Double
    }

    private func extractMetrics(from observation: VNHumanBodyPoseObservation) -> PoseMetrics? {
        guard
            let nose = try? observation.recognizedPoint(.nose),
            let leftShoulder = try? observation.recognizedPoint(.leftShoulder),
            let rightShoulder = try? observation.recognizedPoint(.rightShoulder),
            let leftEar = try? observation.recognizedPoint(.leftEar),
            let rightEar = try? observation.recognizedPoint(.rightEar)
        else { return nil }

        // Require reasonable confidence
        let minConfidence: Float = 0.3
        guard nose.confidence > minConfidence,
              leftShoulder.confidence > minConfidence,
              rightShoulder.confidence > minConfidence,
              leftEar.confidence > minConfidence,
              rightEar.confidence > minConfidence
        else { return nil }

        let shoulderMidY = (leftShoulder.location.y + rightShoulder.location.y) / 2
        let shoulderMidX = (leftShoulder.location.x + rightShoulder.location.x) / 2
        let earMidY = (leftEar.location.y + rightEar.location.y) / 2

        let shoulderWidth = abs(leftShoulder.location.x - rightShoulder.location.x)
        guard shoulderWidth > 0.01 else { return nil } // Prevent division by near-zero

        // In Vision coordinates, Y increases upward. Nose above shoulders = positive.
        let noseShoulderDist = nose.location.y - shoulderMidY
        let earShoulderDist = earMidY - shoulderMidY

        return PoseMetrics(
            noseShoulderRatio: noseShoulderDist / shoulderWidth,
            earShoulderRatio: earShoulderDist / shoulderWidth,
            shoulderWidth: shoulderWidth
        )
    }

    // MARK: - Calibration

    private func addCalibrationSample(_ metrics: PoseMetrics) {
        calNoseRatioSum += metrics.noseShoulderRatio
        calEarRatioSum += metrics.earShoulderRatio
        calShoulderWidthSum += metrics.shoulderWidth
        calibrationSamples += 1

        if calibrationSamples >= Self.calibrationSamplesNeeded {
            let n = Double(calibrationSamples)
            baselineNoseShoulderRatio = calNoseRatioSum / n
            baselineEarShoulderRatio = calEarRatioSum / n
            baselineShoulderWidth = calShoulderWidthSum / n
            isCalibrated = true
            print("[PostureMonitor] Calibrated — nose ratio: \(String(format: "%.3f", baselineNoseShoulderRatio)), ear ratio: \(String(format: "%.3f", baselineEarShoulderRatio)), shoulder width: \(String(format: "%.3f", baselineShoulderWidth))")
        }
    }

    // MARK: - Posture evaluation

    private func evaluatePosture(_ metrics: PoseMetrics) {
        var bad = false

        // 1. Nose dropped relative to shoulders (slouching / head drooping)
        let noseDrop = baselineNoseShoulderRatio - metrics.noseShoulderRatio
        if noseDrop > sensitivity {
            bad = true
        }

        // 2. Ears closer to shoulders (forward head posture / leaning in)
        let earDrop = baselineEarShoulderRatio - metrics.earShoulderRatio
        if earDrop > sensitivity {
            bad = true
        }

        // 3. Shoulder width narrowed significantly (rounding shoulders)
        if baselineShoulderWidth > 0.01 {
            let widthDrop = (baselineShoulderWidth - metrics.shoulderWidth) / baselineShoulderWidth
            if widthDrop > sensitivity {
                bad = true
            }
        }

        if bad {
            consecutiveBadFrames += 1
            if consecutiveBadFrames >= badFramesThreshold && !nudgeFiredForCurrentStreak {
                nudgeFiredForCurrentStreak = true
                DispatchQueue.main.async { [weak self] in
                    self?.onBadPostureDetected?()
                }
            }
        } else {
            if nudgeFiredForCurrentStreak {
                // User corrected their posture
                DispatchQueue.main.async { [weak self] in
                    self?.onPostureCorrected?()
                }
            }
            consecutiveBadFrames = 0
            nudgeFiredForCurrentStreak = false
        }
    }
}

// MARK: - Frame grabber delegate

/// Captures a single frame then stops. Used so the camera runs only
/// for the brief instant needed to grab one image.
private final class FrameGrabber: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let handler: (CVPixelBuffer) -> Void
    private var fired = false

    init(handler: @escaping (CVPixelBuffer) -> Void) {
        self.handler = handler
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !fired else { return }
        fired = true

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        handler(pixelBuffer)
    }
}
