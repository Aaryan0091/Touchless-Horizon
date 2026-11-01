import AppKit
import AVFoundation
import Vision
import Speech
import ApplicationServices

private let mint = NSColor(calibratedRed: 0xa8/255, green: 0xf5/255, blue: 0xe9/255, alpha: 1)

private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
    hypot(a.x - b.x, a.y - b.y)
}

private struct HandSample {
    let index: CGPoint
    let pinchRatio: CGFloat?
    let palm: CGPoint
    let extendedFingers: Int
    let interactionsReliable: Bool
}

private final class PointerController {
    var feedback: ((String) -> Void)?
    var pinchFeedback: ((String) -> Void)?
    var dwellProgress: ((Double, CGPoint?) -> Void)?
    var enabled = false { didSet { reset() } }
    var dwellEnabled = false { didSet { resetDwell() } }
    var pinchEnabled = true
    var swipeEnabled = false { didSet { swipeStart = nil } }
    var dwellDuration: TimeInterval = 1.2
    private var engine = GesturePointerEngine()
    private var clutch = PointerClutch()
    private var pauseState = GesturePauseState()
    var voicePaused: Bool { pauseState.voicePaused }
    private var anchor: CGPoint?
    private var dwellElement: AXUIElement?
    private var dwellBlockedPoint: CGPoint?
    private var anchorTime = Date()
    private var dwellFired = false
    private var lastClick = Date.distantPast
    private var swipeStart: (x: CGFloat, time: Date)?
    private var lastSwipe = Date.distantPast

    func reset() {
        engine.reset()
        clutch = PointerClutch()
        pauseState = GesturePauseState()
        dwellBlockedPoint = nil
        resetDwell()
        swipeStart = nil
        pinchFeedback?(enabled ? "Separate thumb and index to get ready" : "Off")
    }

    private func resetDwell() {
        anchor = nil
        dwellElement = nil
        dwellFired = false
        dwellProgress?(0, nil)
    }

    func setClutched(_ paused: Bool) {
        guard enabled else { return }
        pauseState.setFist(paused)
        applyPauseState()
    }

    func pauseByVoice() {
        pauseState.pause()
        applyPauseState()
    }

    func resumeByVoice() {
        pauseState.resume()
        applyPauseState()
    }

    private func applyPauseState() {
        let paused = pauseState.paused
        let changed = clutch.paused != paused
        clutch.setPaused(paused)
        if paused || changed {
            engine.reset()
            swipeStart = nil
            resetDwell()
            pinchFeedback?(pauseState.voicePaused ? "Voice paused — say resume gestures; microphone stays on" :
                paused ? "Fist — pointer paused; open hand to resume" : "Resumed here — separate fingertips before clicking")
        }
    }

    func pauseTracking(fingertipsOnly: Bool) {
        guard enabled, !clutch.paused else { return }
        let time = ProcessInfo.processInfo.systemUptime
        if fingertipsOnly { engine.uncertain(time: time) }
        else { engine.missing(time: time) }
        pinchFeedback?(fingertipsOnly ? "Palm visible — show thumb and index" : "Tracking paused — pointer held")
        swipeStart = nil
        resetDwell()
    }

    func update(_ hand: HandSample?) {
        guard enabled, !clutch.paused else { return }
        guard let hand, AXIsProcessTrusted() else {
            engine.missing(time: ProcessInfo.processInfo.systemUptime)
            pinchFeedback?("Keep your hand and fingertips in view")
            swipeStart = nil
            resetDwell()
            return
        }
        let time = ProcessInfo.processInfo.systemUptime
        let now = Date()
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let currentCursor = CGEvent(source: nil)?.location ?? engine.position ?? .zero
        let input = GestureGeometry.screenPoint(hand.index, bounds: bounds)
        guard let target = clutch.target(input, cursor: currentCursor, bounds: bounds) else { return }
        let ratio = hand.pinchRatio
        let result = engine.update(target: target, pinchRatio: pinchEnabled ? ratio : nil,
            time: time, currentCursor: CGEvent(source: nil)?.location)
        pinchFeedback?(engine.pinchStatus)
        guard let decision = result else { return }
        let next = decision.position
        let holding = decision.holding
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: next, mouseButton: .left)?.post(tap: .cghidEventTap)

        if decision.click {
            click(at: next)
            lastClick = now
            feedback?("Pinch click")
            resetDwell()
            dwellBlockedPoint = next
        }

        if swipeEnabled && hand.interactionsReliable && hand.extendedFingers >= 4 && (ratio ?? 0) >= 0.70 {
            let palmX = hand.palm.x
            if let start = swipeStart {
                let elapsed = now.timeIntervalSince(start.time)
                let delta = palmX - start.x
                if elapsed < 0.75 && abs(delta) > 0.22 && now.timeIntervalSince(lastSwipe) > 1.0 {
                    // Mirrored camera movement: physical right moves to the right.
                    KeySender.press(delta < 0 ? .rightArrow : .leftArrow)
                    feedback?(delta < 0 ? "Swipe right: next" : "Swipe left: previous")
                    lastSwipe = now
                    swipeStart = nil
                    anchor = nil
                    dwellProgress?(0, nil)
                } else if elapsed >= 0.75 {
                    swipeStart = (palmX, now)
                }
            } else {
                swipeStart = (palmX, now)
            }
        } else {
            swipeStart = nil
        }

        guard dwellEnabled && hand.interactionsReliable && !holding && now.timeIntervalSince(lastClick) > 0.8 else { resetDwell(); return }
        if let blocked = dwellBlockedPoint {
            guard distance(blocked, next) > 30 else { resetDwell(); return }
            dwellBlockedPoint = nil
        }
        guard let element = actionableElement(at: next) else { resetDwell(); return }
        if dwellElement == nil || !CFEqual(dwellElement!, element) {
            resetDwell()
            dwellElement = element
        }
        if let anchor, distance(anchor, next) < 18, distance(target, next) < 26 {
            let progress = min(now.timeIntervalSince(anchorTime) / dwellDuration, 1)
            if !dwellFired {
                dwellProgress?(progress, next)
                if progress >= 1 && now.timeIntervalSince(lastClick) > 0.6 {
                    click(at: next)
                    lastClick = now
                    dwellFired = true
                    dwellBlockedPoint = next
                    feedback?("Dwell click")
                    dwellProgress?(0, nil)
                }
            } else {
                dwellProgress?(0, nil)
            }
        } else {
            self.anchor = next
            anchorTime = now
            dwellFired = false
            dwellProgress?(0, nil)
        }
    }

    func clickCurrent(count: Int = 1) {
        guard AXIsProcessTrusted() else { return }
        click(at: CGEvent(source: nil)?.location ?? engine.position ?? .zero, count: count)
        feedback?("Voice click")
    }

    private func click(at point: CGPoint, count: Int = 1) {
        for clickNumber in 1...max(1, min(count, 2)) {
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
                event?.setIntegerValueField(.mouseEventClickState, value: Int64(clickNumber))
                event?.post(tap: .cghidEventTap)
            }
        }
        NSSound.beep()
    }

    private func actionableElement(at point: CGPoint) -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element) == .success,
              let element else { return nil }
        let roles: Set<String> = ["AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXMenuItem", "AXMenuButton", "AXPopUpButton", "AXTab", "AXSwitch"]
        var current: AXUIElement? = element
        for _ in 0..<3 {
            guard let candidate = current else { break }
            var roleValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(candidate, kAXRoleAttribute as CFString, &roleValue) == .success,
               let role = roleValue as? String, roles.contains(role) { return candidate }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(candidate, kAXParentAttribute as CFString, &parent) == .success else { break }
            current = (parent as! AXUIElement)
        }
        return nil
    }
}

private enum VirtualKey: CGKeyCode {
    case a = 0, o = 31, w = 13, tab = 48, space = 49
    case equal = 24, minus = 27
    case leftArrow = 123, rightArrow = 124, downArrow = 125, upArrow = 126
}

private enum KeySender {
    static func press(_ key: VirtualKey, modifiers: CGEventFlags = []) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key.rawValue, keyDown: down)
            event?.flags = modifiers
            event?.post(tap: .cghidEventTap)
        }
    }

    static func scroll(_ lines: Int32) {
        CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
    }
}

private final class CameraTracker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onHand: ((HandSample?) -> Void)?
    var onStatus: ((String) -> Void)?
    var onUncertain: ((Bool) -> Void)?
    var onFormat: ((Int, Int) -> Void)?
    var onClutch: ((Bool) -> Void)?
    private let queue = DispatchQueue(label: "TouchlessHorizon.camera")
    private let session = AVCaptureSession()
    private let request = VNDetectHumanHandPoseRequest()
    private var running = false
    private var desiredRunning = false
    private var trackedPalm: CGPoint?
    private var trackedAt: TimeInterval = 0
    private var trackingGate = HandTrackingGate()
    private var fistGate = FistGate()
    private weak var preview: AVCaptureVideoPreviewLayer?
    private var lastFormat: (Int, Int)?

    override init() {
        super.init()
        request.maximumHandCount = 2
    }

    func clearFistPause() {
        queue.async { self.fistGate = FistGate() }
    }

    func makePreviewLayer() -> AVCaptureVideoPreviewLayer {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspect
        preview = layer
        return layer
    }

    func start() {
        queue.async { [self] in
            self.desiredRunning = true
            DispatchQueue.main.async { self.onStatus?("Starting camera…") }
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                self.configureAndStart()
            case .notDetermined:
                DispatchQueue.main.async { self.onStatus?("Allow camera access in the macOS prompt") }
                AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                    guard let self else { return }
                    self.queue.async {
                        guard self.desiredRunning else { return }
                        if granted { self.configureAndStart() }
                        else { DispatchQueue.main.async { self.onStatus?("Camera access denied") } }
                    }
                }
            default:
                DispatchQueue.main.async { self.onStatus?("Camera access denied") }
            }
        }
    }

    func stop() {
        queue.async {
            self.desiredRunning = false
            self.trackedPalm = nil
            self.trackingGate.reset()
            self.fistGate = FistGate()
            self.session.stopRunning()
            self.running = false
            DispatchQueue.main.async { self.onStatus?("Camera off"); self.onHand?(nil) }
        }
    }

    private func configureAndStart() {
        guard desiredRunning else { return }
        if !running {
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device) else {
                DispatchQueue.main.async { self.onStatus?("No camera found") }
                return
            }
            session.beginConfiguration()
            if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
            else if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
            else { session.sessionPreset = .medium }
            if session.inputs.isEmpty && session.canAddInput(input) { session.addInput(input) }
            if session.outputs.isEmpty {
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: queue)
                if session.canAddOutput(output) { session.addOutput(output) }
            }
            session.commitConfiguration()
            do {
                try device.lockForConfiguration()
                if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
                device.unlockForConfiguration()
            } catch { /* Keep the camera's existing automatic settings if configuration is unavailable. */ }
            running = true
        }
        session.startRunning()
        DispatchQueue.main.async {
            if let connection = self.preview?.connection, connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
            }
            self.onStatus?("Camera active")
        }
    }

    private func reportGap(_ state: HandTrackingState) {
        DispatchQueue.main.async {
            switch state {
            case .fingertipsUnclear: self.onUncertain?(true)
            case .brieflyMissing: self.onUncertain?(false)
            default: self.onHand?(nil)
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard desiredRunning else { return }
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        if lastFormat?.0 != width || lastFormat?.1 != height {
            lastFormat = (width, height)
            DispatchQueue.main.async { self.onFormat?(width, height) }
        }
        do {
            try VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up).perform([request])
            let time = ProcessInfo.processInfo.systemUptime
            if time - trackedAt > 0.5 { trackedPalm = nil }
            typealias PosePoints = [VNHumanHandPoseObservation.JointName: VNRecognizedPoint]
            let candidates = (request.results ?? []).compactMap { observation -> (points: PosePoints, palm: CGPoint)? in
                guard let points = try? observation.recognizedPoints(.all) else { return nil }
                let palmJoints: [VNHumanHandPoseObservation.JointName] = [.wrist, .indexMCP, .middleMCP, .ringMCP, .littleMCP]
                let fingerJoints: [VNHumanHandPoseObservation.JointName] = [.indexPIP, .middlePIP, .ringPIP, .littlePIP]
                func landmarks(_ names: [VNHumanHandPoseObservation.JointName]) -> [HandLandmark] {
                    names.compactMap { name in
                        guard let point = points[name] else { return nil }
                        return HandLandmark(point: point.location, confidence: point.confidence)
                    }
                }
                let palmPoints = landmarks(palmJoints)
                let anchor = HandTrackingGeometry.palmAnchor(palmPoints) ??
                    HandTrackingGeometry.palmAnchor(palmPoints + landmarks(fingerJoints))
                guard let anchor else { return nil }
                return (points, anchor)
            }
            let selected: (points: PosePoints, palm: CGPoint)?
            if let palm = trackedPalm {
                selected = candidates.min { distance($0.palm, palm) < distance($1.palm, palm) }
            } else {
                selected = candidates.first
            }
            guard let selected else {
                reportGap(trackingGate.update(palmVisible: false, indexConfidence: nil, time: time))
                return
            }
            let points = selected.points
            trackedPalm = selected.palm
            trackedAt = time
            func p(_ name: VNHumanHandPoseObservation.JointName, confidence: Float = 0.30) -> CGPoint? {
                guard let value = points[name], value.confidence >= confidence,
                      value.location.x.isFinite, value.location.y.isFinite else { return nil }
                return value.location
            }
            let fingerJoints: [(VNHumanHandPoseObservation.JointName, VNHumanHandPoseObservation.JointName, VNHumanHandPoseObservation.JointName)] = [
                (.indexTip, .indexPIP, .indexMCP), (.middleTip, .middlePIP, .middleMCP),
                (.ringTip, .ringPIP, .ringMCP), (.littleTip, .littlePIP, .littleMCP)
            ]
            let postures = fingerJoints.map { tip, pip, mcp -> FingerPosture in
                guard let t = p(tip, confidence: 0.18), let i = p(pip, confidence: 0.18),
                      let m = p(mcp, confidence: 0.18), let w = p(.wrist, confidence: 0.18) else { return .unclear }
                return FingerPosture.classify(tip: t, pip: i, mcp: m, wrist: w)
            }
            let paused = fistGate.update(postures, time: time)
            DispatchQueue.main.async { self.onClutch?(paused) }
            // Detect the fist before requiring a visible index fingertip. Hidden
            // fingertips never release an already paused cursor.
            if paused { return }
            let tracking = trackingGate.update(palmVisible: true, indexConfidence: points[.indexTip]?.confidence, time: time)
            guard tracking == .tracked, let tip = points[.indexTip], tip.location.x.isFinite, tip.location.y.isFinite else {
                reportGap(tracking == .tracked ? .fingertipsUnclear : tracking)
                return
            }
            let index = tip.location
            let wrist = p(.wrist, confidence: 0.25)
            let interactionsReliable = tip.confidence >= 0.35
            let fingerPairs: [(VNHumanHandPoseObservation.JointName, VNHumanHandPoseObservation.JointName)] = [
                (.indexTip, .indexPIP), (.middleTip, .middlePIP),
                (.ringTip, .ringPIP), (.littleTip, .littlePIP)
            ]
            let extended = fingerPairs.filter { pair in
                guard let tip = p(pair.0), let pip = p(pair.1) else { return false }
                let base = wrist ?? selected.palm
                return distance(tip, base) > distance(pip, base) * 1.13
            }.count
            var pinchRatio: CGFloat?
            if interactionsReliable, let thumb = p(.thumbTip, confidence: 0.35) {
                let aspect = CGFloat(CVPixelBufferGetHeight(buffer)) / CGFloat(CVPixelBufferGetWidth(buffer))
                pinchRatio = GestureGeometry.pinchRatio(index: index, thumb: thumb,
                    indexMCP: p(.indexMCP, confidence: 0.35),
                    littleMCP: p(.littleMCP, confidence: 0.35), imageAspect: aspect,
                    wrist: wrist, middleMCP: p(.middleMCP, confidence: 0.35))
            }
            let sample = HandSample(index: index, pinchRatio: pinchRatio,
                                    palm: selected.palm, extendedFingers: extended,
                                    interactionsReliable: interactionsReliable)
            DispatchQueue.main.async { self.onHand?(sample) }
        } catch {
            DispatchQueue.main.async { self.onStatus?("Hand tracking error: \(error.localizedDescription)") }
        }
    }
}

private final class VoiceController {
    var onCommand: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    var onListening: ((Bool) -> Void)?
    var onInputLevel: ((Double) -> Void)?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var rotationTimer: Timer?
    private var silenceTimer: Timer?
    private var silenceBoundary = VoiceSilenceBoundary()
    private var utteranceSettler = SpeechUtteranceSettler()
    private var enabled = false
    private var restarting = false
    private var generation = 0
    private var commandGate = VoiceCommandGate()
    private var recognitionID = UUID()
    private var lastLevelPublish = Date.distantPast
    private var preferOnDevice = true
    private let commands = ["pause gestures", "resume gestures", "toggle theme", "switch app", "zoom in", "zoom out",
                            "scroll down", "scroll up", "double click", "previous",
                            "resume", "next", "click", "open", "close", "help", "pause"]

    func start() {
        guard !enabled else { return }
        enabled = true
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            authorizeSpeech()
        case .notDetermined:
            onStatus?("Allow microphone access in the macOS prompt")
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.enabled else { return }
                    if granted { self.authorizeSpeech() }
                    else { self.fail("Microphone denied in System Settings") }
                }
            }
        default:
            fail("Microphone denied in System Settings")
        }
    }

    private func authorizeSpeech() {
        guard enabled else { return }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            startAudio()
        case .notDetermined:
            onStatus?("Allow Speech Recognition in the macOS prompt")
            SFSpeechRecognizer.requestAuthorization { [weak self] authorization in
                DispatchQueue.main.async {
                    guard let self, self.enabled else { return }
                    if authorization == .authorized { self.startAudio() }
                    else { self.fail("Speech Recognition denied in System Settings") }
                }
            }
        default:
            fail("Speech Recognition denied in System Settings")
        }
    }

    func stop() {
        enabled = false
        generation += 1
        restarting = false
        cleanup()
        onListening?(false)
        onStatus?("Microphone off")
    }

    private func fail(_ message: String) {
        enabled = false
        generation += 1
        restarting = false
        cleanup()
        onListening?(false)
        onStatus?(message)
    }

    private func cleanup() {
        recognitionID = UUID()
        silenceTimer?.invalidate()
        silenceTimer = nil
        rotationTimer?.invalidate()
        rotationTimer = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    private func startAudio() {
        guard enabled else { return }
        guard let recognizer, recognizer.isAvailable else {
            fail("Speech service unavailable; check language or network")
            return
        }
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { fail("No microphone input format"); return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = false
        request.contextualStrings = commands
        if preferOnDevice && recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request
        let sessionID = UUID()
        recognitionID = sessionID
        silenceBoundary = VoiceSilenceBoundary()
        utteranceSettler = SpeechUtteranceSettler()
        commandGate = VoiceCommandGate()
        engine.inputNode.removeTap(onBus: 0)
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self, weak request] buffer, _ in
            request?.append(buffer)
            guard let self, let channel = buffer.floatChannelData?[0] else { return }
            let now = Date()
            guard now.timeIntervalSince(self.lastLevelPublish) >= 0.2 else { return }
            self.lastLevelPublish = now
            let count = Int(buffer.frameLength)
            guard count > 0 else { return }
            var sum: Float = 0
            for i in 0..<count { sum += channel[i] * channel[i] }
            let level = min(Double(sqrt(sum / Float(count))) * 8, 1)
            DispatchQueue.main.async {
                guard self.enabled, self.recognitionID == sessionID else { return }
                self.onInputLevel?(level)
                self.silenceBoundary.audio(level: level, time: ProcessInfo.processInfo.systemUptime)
            }
        }
        engine.prepare()
        do { try engine.start() }
        catch { fail("Microphone start failed: \(error.localizedDescription)"); return }
        onListening?(true)
        onStatus?("Listening — say “help” or “next”")
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.enabled, self.recognitionID == sessionID else { return }
                if let result {
                    let phrase = result.bestTranscription.formattedString
                    self.silenceBoundary.heard(phrase, time: ProcessInfo.processInfo.systemUptime)
                    self.onStatus?("Heard: \(String(phrase.suffix(48)))")
                    let words = result.bestTranscription.segments.map {
                        VoiceWord(text: $0.substring, start: $0.timestamp, duration: $0.duration)
                    }
                    self.utteranceSettler.update(phrase: phrase, words: words,
                        time: ProcessInfo.processInfo.systemUptime)
                    self.dispatchSettledCommand(final: result.isFinal)
                    if self.restarting { return }
                }
                if let error {
                    if self.preferOnDevice && recognizer.supportsOnDeviceRecognition {
                        self.preferOnDevice = false
                        self.onStatus?("On-device speech failed; trying Apple speech service")
                    } else {
                        self.onStatus?("Speech error: \(error.localizedDescription)")
                    }
                    self.restart(after: 1.5)
                } else if result?.isFinal == true {
                    self.restart(after: 0.35)
                }
            }
        }
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.enabled, !self.restarting else { return }
            self.dispatchSettledCommand()
            guard !self.restarting else { return }
            if self.silenceBoundary.shouldRefresh(time: ProcessInfo.processInfo.systemUptime) {
                self.onStatus?("Listening — ready for a new command")
                self.restart(after: 0.05)
            }
        }
        rotationTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { [weak self] _ in
            self?.restart(after: 0.35)
        }
    }

    private func dispatchSettledCommand(final: Bool = false) {
        guard let words = utteranceSettler.takeReady(time: ProcessInfo.processInfo.systemUptime, final: final),
              let command = commandGate.command(in: words, commands: commands) else { return }
        onCommand?(command)
        if command == "pause" || command == "resume" { restart(after: 0.15) }
    }

    private func restart(after delay: TimeInterval) {
        guard enabled, !restarting else { return }
        restarting = true
        let currentGeneration = generation
        cleanup()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard self.enabled, self.generation == currentGeneration else { return }
            self.restarting = false
            self.startAudio()
        }
    }


}

private final class DwellOverlay: NSPanel {
    private let ring = CAShapeLayer()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 56, height: 56),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView?.wantsLayer = true
        ring.frame = CGRect(x: 0, y: 0, width: 56, height: 56)
        ring.path = CGPath(ellipseIn: CGRect(x: 5, y: 5, width: 46, height: 46), transform: nil)
        ring.fillColor = NSColor.clear.cgColor
        ring.strokeColor = mint.cgColor
        ring.lineWidth = 5
        ring.strokeEnd = 0
        contentView?.layer?.addSublayer(ring)
        orderOut(nil)
    }

    func show(progress: Double, at quartzPoint: CGPoint?) {
        guard progress > 0, let point = quartzPoint else { orderOut(nil); return }
        let main = CGDisplayBounds(CGMainDisplayID())
        let cocoaY = main.height - (point.y - main.minY)
        setFrameOrigin(NSPoint(x: point.x - 28, y: cocoaY - 28))
        ring.strokeEnd = CGFloat(progress)
        orderFrontRegardless()
    }
}

private final class AppController: NSObject, NSApplicationDelegate {
    private let pointer = PointerController()
    private let camera = CameraTracker()
    private let voice = VoiceController()
    private let overlay = DwellOverlay()
    private var window: NSWindow!
    private var cameraLabel: NSTextField!
    private var micLabel: NSTextField!
    private var inputLevelLabel: NSTextField!
    private var actionLabel: NSTextField!
    private var pinchLabel: NSTextField!
    private var accessLabel: NSTextField!
    private var gestureButton: NSButton!
    private var voiceButton: NSButton!
    private var settingsButton: NSButton!
    private var practiceLabel: NSTextField!
    private var practiceClicks = 0
    private var previewFormatLabel: NSTextField!
    private var gestureOn = false
    private var voiceOn = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        camera.onHand = { [weak self] hand in
            guard let self else { return }
            if self.gestureOn && !self.pointer.voicePaused { self.cameraLabel.stringValue = hand == nil ? "Camera active • searching for hand" : "Camera active • hand tracked" }
            self.pointer.update(hand)
        }
        camera.onClutch = { [weak self] paused in
            guard let self, self.gestureOn else { return }
            self.pointer.setClutched(paused)
            if paused && !self.pointer.voicePaused { self.cameraLabel.stringValue = "Camera active • FIST PAUSE — open hand to resume" }
        }
        camera.onStatus = { [weak self] status in self?.cameraLabel.stringValue = status }
        camera.onFormat = { [weak self] width, height in
            self?.previewFormatLabel.stringValue = "Mirrored preview · \(width) × \(height)"
        }
        camera.onUncertain = { [weak self] fingertipsOnly in
            guard let self, self.gestureOn else { return }
            if self.pointer.voicePaused { return }
            self.cameraLabel.stringValue = fingertipsOnly ?
                "Camera active • palm tracked, fingertip unclear" : "Camera active • brief gap, pointer held"
            self.pointer.pauseTracking(fingertipsOnly: fingertipsOnly)
        }
        voice.onStatus = { [weak self] status in self?.micLabel.stringValue = status }
        voice.onInputLevel = { [weak self] level in
            guard let self, self.voiceOn else { return }
            self.inputLevelLabel.stringValue = "Mic signal: \(Int(level * 100))%"
        }
        voice.onListening = { [weak self] listening in
            self?.voiceOn = listening
            self?.voiceButton.title = listening ? "Stop voice" : "Start voice"
            if !listening { self?.inputLevelLabel.stringValue = "Mic signal: —" }
        }
        voice.onCommand = { [weak self] command in self?.run(command) }
        pointer.feedback = { [weak self] message in self?.announce(message) }
        pointer.pinchFeedback = { [weak self] message in self?.pinchLabel.stringValue = "Pinch: \(message)" }
        pointer.dwellProgress = { [weak self] progress, point in self?.overlay.show(progress: progress, at: point) }
        refreshAccess()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshAccess() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func buildMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Show Touchless Horizon", action: #selector(showWindow), keyEquivalent: "0")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Touchless Horizon", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        NSApp.mainMenu = menu
    }

    @objc private func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        camera.stop()
        voice.stop()
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Touchless Horizon"
        window.center()
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1)
        let root = NSView(frame: window.contentView!.bounds)
        root.wantsLayer = true
        root.layer?.backgroundColor = window.backgroundColor.cgColor
        window.contentView = root
        let content = NSView(frame: NSRect(x: 0, y: 80, width: 560, height: 600))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1).cgColor
        root.addSubview(content)
        @discardableResult func previewText(_ text: String, y: CGFloat, height: CGFloat, size: CGFloat, color: NSColor) -> NSTextField {
            let field = NSTextField(wrappingLabelWithString: text)
            field.frame = NSRect(x: 580, y: y, width: 280, height: height)
            field.font = .systemFont(ofSize: size)
            field.textColor = color
            root.addSubview(field)
            return field
        }
        previewText("CAMERA VIEW", y: 625, height: 25, size: 15, color: mint)
        previewText("Keep your whole hand inside the frame.", y: 586, height: 32, size: 13, color: .white)
        let previewView = NSView(frame: NSRect(x: 580, y: 365, width: 280, height: 210))
        previewView.wantsLayer = true
        previewView.layer?.backgroundColor = NSColor.black.cgColor
        previewView.layer?.cornerRadius = 10
        previewView.layer?.masksToBounds = true
        let previewLayer = camera.makePreviewLayer()
        previewLayer.frame = previewView.bounds
        previewView.layer?.addSublayer(previewLayer)
        root.addSubview(previewView)
        previewFormatLabel = previewText("Mirrored camera preview", y: 334, height: 24, size: 12, color: .lightGray)
        previewText("Face your palm toward the camera. Use light from in front of you so your fingertips stay clear.",
                    y: 244, height: 72, size: 14, color: .white)
        previewText("Make a fist to pause. Reposition your hand, then open it to resume from the same cursor position.",
                    y: 148, height: 68, size: 13, color: .lightGray)
        let practice = NSButton(title: "Practice pinch click", target: self, action: #selector(practiceClick))
        practice.frame = NSRect(x: 34, y: 8, width: 235, height: 64)
        practice.bezelStyle = .rounded
        root.addSubview(practice)
        practiceLabel = NSTextField(labelWithString: "Practice clicks: 0")
        practiceLabel.frame = NSRect(x: 286, y: 27, width: 235, height: 28)
        practiceLabel.font = .systemFont(ofSize: 14)
        practiceLabel.textColor = mint
        root.addSubview(practiceLabel)

        func label(_ text: String, size: CGFloat, color: NSColor, y: CGFloat, height: CGFloat = 28) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.font = .systemFont(ofSize: size, weight: size > 22 ? .bold : .regular)
            field.textColor = color
            field.frame = NSRect(x: 34, y: y, width: 490, height: height)
            content.addSubview(field)
            return field
        }
        _ = label("TOUCHLESS HORIZON", size: 28, color: mint, y: 533, height: 38)
        _ = label("Select the app you want voice commands to control", size: 15, color: .white, y: 504)
        accessLabel = label("Checking Accessibility…", size: 13, color: .systemYellow, y: 479)
        settingsButton = NSButton(title: "Open Device Control Settings", target: self, action: #selector(openAccessibilitySettings))
        settingsButton.frame = NSRect(x: 34, y: 442, width: 235, height: 30)
        content.addSubview(settingsButton)

        gestureButton = NSButton(title: "Start gestures", target: self, action: #selector(toggleGestures))
        gestureButton.frame = NSRect(x: 34, y: 380, width: 235, height: 54)
        gestureButton.bezelStyle = .rounded
        content.addSubview(gestureButton)
        voiceButton = NSButton(title: "Start voice", target: self, action: #selector(toggleVoice))
        voiceButton.frame = NSRect(x: 286, y: 380, width: 235, height: 54)
        voiceButton.bezelStyle = .rounded
        content.addSubview(voiceButton)

        cameraLabel = label("Camera off", size: 14, color: mint, y: 343)
        micLabel = label("Microphone off", size: 14, color: mint, y: 315)
        micLabel.frame.size.width = 345
        inputLevelLabel = label("Mic signal: —", size: 13, color: .white, y: 315)
        inputLevelLabel.frame = NSRect(x: 385, y: 315, width: 140, height: 28)
        actionLabel = label("Ready", size: 14, color: .white, y: 285)
        _ = label("GESTURES", size: 14, color: mint, y: 246)
        _ = label("Point to move • Hand down moves the pointer down", size: 13, color: .white, y: 219)
        pinchLabel = label("Pinch: off", size: 13, color: mint, y: 196)
        let dwellToggle = NSButton(checkboxWithTitle: "Hover click (1.2 seconds)", target: self, action: #selector(toggleDwell(_:)))
        dwellToggle.frame = NSRect(x: 34, y: 160, width: 260, height: 28)
        dwellToggle.state = .off
        content.addSubview(dwellToggle)
        let swipeToggle = NSButton(checkboxWithTitle: "Air swipes", target: self, action: #selector(toggleSwipes(_:)))
        swipeToggle.frame = NSRect(x: 320, y: 160, width: 190, height: 28)
        swipeToggle.state = .off
        content.addSubview(swipeToggle)
        _ = label("Hover clicks and swipes are off until you enable them", size: 12, color: .lightGray, y: 133)
        _ = label("VOICE", size: 14, color: mint, y: 90)
        _ = label("Say: next, previous, zoom in/out, click, scroll, open, close", size: 13, color: .white, y: 63)
        _ = label("pause/resume media • pause/resume gestures • help", size: 13, color: .white, y: 40)
    }

    private func refreshAccess() {
        if AXIsProcessTrusted() {
            accessLabel.stringValue = "System control enabled — gestures and voice can control apps"
            accessLabel.textColor = mint
            settingsButton.isHidden = true
        } else {
            accessLabel.stringValue = "System control OFF — enable Touchless Horizon in Settings"
            accessLabel.textColor = .systemYellow
            settingsButton.isHidden = false
        }
    }

    @objc private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func toggleDwell(_ sender: NSButton) {
        pointer.dwellEnabled = sender.state == .on
        announce(pointer.dwellEnabled ? "Hover click enabled" : "Hover click disabled")
    }

    @objc private func practiceClick() {
        practiceClicks += 1
        practiceLabel.stringValue = "Practice clicks: \(practiceClicks)"
    }

    @objc private func toggleSwipes(_ sender: NSButton) {
        pointer.swipeEnabled = sender.state == .on
        announce(pointer.swipeEnabled ? "Air swipes enabled" : "Air swipes disabled")
    }

    @objc private func toggleGestures() {
        if gestureOn {
            gestureOn = false
            pointer.enabled = false
            camera.stop()
            gestureButton.title = "Start gestures"
        } else {
            requestAccessibility()
            gestureOn = true
            pointer.enabled = true
            camera.start()
            gestureButton.title = "Stop gestures"
        }
        refreshAccess()
    }

    @objc private func toggleVoice() {
        if voiceOn {
            voiceOn = false
            voice.stop()
            voiceButton.title = "Start voice"
        } else {
            voiceOn = true
            voice.start()
            voiceButton.title = "Stop voice"
        }
        refreshAccess()
    }

    private func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func announce(_ text: String) {
        actionLabel.stringValue = "Last action: \(text)"
    }

    private func run(_ command: String) {
        refreshAccess()
        if command == "help" { showWindow(); announce("Voice: help"); return }
        if command == "pause gestures" {
            pointer.pauseByVoice()
            cameraLabel.stringValue = gestureOn ? "Camera active • VOICE PAUSED — say resume gestures" : "Gestures paused — say resume gestures to start"
            announce("Voice: pause gestures — gestures held; voice stays listening")
            return
        }
        if command == "resume gestures" {
            if !gestureOn { toggleGestures() }
            camera.clearFistPause()
            pointer.resumeByVoice()
            cameraLabel.stringValue = "Camera active • resuming — open your hand"
            announce("Voice: resume gestures — gesture control enabled")
            return
        }
        guard AXIsProcessTrusted() else {
            announce("Heard \(command), but Accessibility is OFF")
            return
        }
        // Keep the controller visible. Keyboard shortcuts should only go to an
        // app the user explicitly focused, never hide this window to pick one.
        let needsExternalApp = ["next", "previous", "zoom in", "zoom out",
                                "scroll down", "scroll up", "open", "close"]
        if NSApp.isActive && needsExternalApp.contains(command) {
            announce("Select the app to control, then say “\(command)”")
            return
        }
        execute(command)
    }

    private func execute(_ command: String) {
        switch command {
        case "pause", "resume":
            announce(MediaPlayback.perform(command))
            return
        case "next": KeySender.press(.rightArrow)
        case "previous": KeySender.press(.leftArrow)
        case "zoom in": KeySender.press(.equal, modifiers: .maskCommand)
        case "zoom out": KeySender.press(.minus, modifiers: .maskCommand)
        case "scroll down": KeySender.scroll(-5)
        case "scroll up": KeySender.scroll(5)
        case "click": pointer.clickCurrent()
        case "double click": pointer.clickCurrent(count: 2)
        case "open": KeySender.press(.o, modifiers: .maskCommand)
        case "close": KeySender.press(.w, modifiers: .maskCommand)
        case "switch app": KeySender.press(.tab, modifiers: .maskCommand)
        case "toggle theme": toggleAppearance()
        default: return
        }
        announce("Voice: \(command)")
        NSSound.beep()
    }

    private func toggleAppearance() {
        let source = "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if error != nil { announce("Theme change needs Automation permission") }
    }
}

let application = NSApplication.shared
private let controller = AppController()
application.delegate = controller
application.setActivationPolicy(.regular)
application.run()
