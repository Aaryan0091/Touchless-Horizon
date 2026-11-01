import Foundation
import CoreGraphics

struct HandLandmark {
    let point: CGPoint
    let confidence: Float
}

enum HandTrackingState: Equatable {
    case tracked, fingertipsUnclear, brieflyMissing, lost
}

enum HandTrackingGeometry {
    static func palmAnchor(_ landmarks: [HandLandmark]) -> CGPoint? {
        let visible = landmarks.filter {
            $0.confidence.isFinite && $0.confidence >= 0.18 &&
            $0.point.x.isFinite && $0.point.y.isFinite
        }
        guard visible.count >= 2 else { return nil }
        let weight = visible.reduce(CGFloat.zero) { $0 + CGFloat($1.confidence) }
        return CGPoint(x: visible.reduce(CGFloat.zero) { $0 + $1.point.x * CGFloat($1.confidence) } / weight,
                       y: visible.reduce(CGFloat.zero) { $0 + $1.point.y * CGFloat($1.confidence) } / weight)
    }
}

/// Different acquire/retain thresholds avoid losing an established hand on every weak frame.
struct HandTrackingGate {
    private var lastHandAt: TimeInterval?
    private var lastIndexAt: TimeInterval?

    mutating func reset() { lastHandAt = nil; lastIndexAt = nil }

    mutating func update(palmVisible: Bool, indexConfidence: Float?, time: TimeInterval) -> HandTrackingState {
        guard palmVisible else {
            return time - (lastHandAt ?? -Double.infinity) <= 0.35 ? .brieflyMissing : .lost
        }
        lastHandAt = time
        let retaining = time - (lastIndexAt ?? -Double.infinity) < 0.5
        let threshold: Float = retaining ? 0.18 : 0.30
        guard let confidence = indexConfidence, confidence.isFinite, confidence >= threshold else {
            return .fingertipsUnclear
        }
        lastIndexAt = time
        return .tracked
    }
}

enum GestureGeometry {
    static func pinchRatio(index: CGPoint, thumb: CGPoint, indexMCP: CGPoint?,
                           littleMCP: CGPoint?, imageAspect: CGFloat,
                           wrist: CGPoint? = nil, middleMCP: CGPoint? = nil) -> CGFloat? {
        func imageDistance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
            hypot(a.x - b.x, (a.y - b.y) * imageAspect)
        }
        var palm: CGFloat = 0
        if let indexMCP, let littleMCP { palm = imageDistance(indexMCP, littleMCP) }
        if let wrist, let middleMCP { palm = max(palm, imageDistance(wrist, middleMCP) * 0.75) }
        guard palm >= 0.04 else { return nil }
        return imageDistance(index, thumb) / palm
    }

    static func screenPoint(_ point: CGPoint, bounds: CGRect) -> CGPoint {
        // Vision starts at bottom-left; Quartz screen events start at top-left.
        let margin: CGFloat = 0.06
        func unit(_ value: CGFloat) -> CGFloat {
            min(max((value - margin) / (1 - 2 * margin), 0), 1)
        }
        return CGPoint(x: bounds.minX + unit(1 - point.x) * bounds.width,
                       y: bounds.minY + unit(1 - point.y) * bounds.height)
    }
}

/// A click requires stable open → stable closed → stable open, not a threshold edge.
struct PinchRecognizer {
    enum Phase { case openToArm, ready, closing, release, unclear }
    private(set) var armed = false
    private(set) var held = false
    private(set) var phase: Phase = .openToArm
    private var openSince: TimeInterval?
    private var closedSince: TimeInterval?
    private var closedSamples = 0
    private var lastReliableTime: TimeInterval?
    private var lastClick = -Double.infinity

    mutating func reset() {
        armed = false
        held = false
        openSince = nil
        closedSince = nil
        closedSamples = 0
        lastReliableTime = nil
        phase = .openToArm
    }

    mutating func unavailable(time: TimeInterval) {
        // Tip overlap may hide the thumb briefly. Preserve readiness, never infer a click.
        if time - (lastReliableTime ?? -Double.infinity) > 0.22 { reset() }
        openSince = nil
        closedSince = nil
        closedSamples = 0
        phase = .unclear
    }

    mutating func update(ratio: CGFloat, time: TimeInterval) -> Bool {
        guard ratio.isFinite, ratio >= 0 else { reset(); return false }
        if let last = lastReliableTime, time - last > 0.22 { reset() }
        lastReliableTime = time
        if ratio >= 0.60 {
            closedSince = nil
            closedSamples = 0
            if openSince == nil { openSince = time }
            if time - openSince! >= 0.12 {
                armed = true
                held = false
            }
            phase = held ? .release : (armed ? .ready : .openToArm)
        } else {
            openSince = nil
            if ratio <= 0.38 && armed && !held {
                if closedSince == nil { closedSince = time }
                closedSamples += 1
                phase = .closing
                if closedSamples >= 2 && time - closedSince! >= 0.06 && time - lastClick >= 0.50 {
                    held = true
                    armed = false
                    closedSince = nil
                    closedSamples = 0
                    lastClick = time
                    phase = .release
                    return true
                }
            } else {
                if ratio >= 0.46 || !armed || held {
                    closedSince = nil
                    closedSamples = 0
                }
                phase = held ? .release : (armed ? .ready : .openToArm)
            }
        }
        return false
    }

    func shouldHoldPointer(ratio: CGFloat, time: TimeInterval) -> Bool {
        // Never lock movement just because the thumb rests near the index finger.
        // Freeze only during a real closing candidate and briefly after its click.
        if time >= lastClick && time - lastClick < 0.10 { return true }
        if let since = closedSince, ratio <= 0.38, time - since <= 0.20 { return true }
        return false
    }
}

/// Median rejection handles isolated bad landmarks; a time-based filter handles jitter.
struct CursorFilter {
    private var samples: [CGPoint] = []
    private(set) var position: CGPoint?
    private var lastTime: TimeInterval?

    mutating func reset(seed: CGPoint? = nil) {
        samples.removeAll(keepingCapacity: true)
        position = seed
        lastTime = nil
    }

    mutating func update(target: CGPoint, time: TimeInterval) -> CGPoint {
        let dt = min(max(time - (lastTime ?? (time - 1.0 / 30)), 1.0 / 120), 0.1)
        lastTime = time
        // Every valid sample enters a finite window. Direction changes cannot get
        // rejected indefinitely by comparison with an obsolete accepted location.
        samples.append(target)
        let window = dt > 0.045 ? 3 : 5
        while samples.count > window { samples.removeFirst() }
        let xs = samples.map(\.x).sorted()
        let ys = samples.map(\.y).sorted()
        func middle(_ values: [CGFloat]) -> CGFloat {
            let index = values.count / 2
            return values.count % 2 == 0 ? (values[index - 1] + values[index]) / 2 : values[index]
        }
        let median = CGPoint(x: middle(xs), y: middle(ys))
        guard let current = position else { position = median; return median }
        let delta = hypot(median.x - current.x, median.y - current.y)
        let deadzone: CGFloat = 3.5
        if delta <= deadzone { return current }
        // Adapt to sustained displacement, not raw speed: shaking must not reduce filtering.
        let response = min(max((delta - 30) / 250, 0), 1)
        let timeConstant = 0.18 - 0.12 * response
        let alpha = CGFloat(1 - exp(-dt / timeConstant))
        let step = min(alpha * (delta - deadzone), CGFloat(dt) * 1700)
        let result = CGPoint(x: current.x + step * (median.x - current.x) / delta,
                             y: current.y + step * (median.y - current.y) / delta)
        position = result
        return result
    }
}

struct PointerDecision {
    let position: CGPoint
    let click: Bool
    let holding: Bool
}

/// The same movement/click integration is used by the app and deterministic tests.
struct GesturePointerEngine {
    private struct ClickAnchor {
        let position: CGPoint
        let startedAt: TimeInterval
        var lowestRatio: CGFloat
        var progressedAt: TimeInterval
        var clickedAt: TimeInterval?
    }
    private var filter = CursorFilter()
    private var pinch = PinchRecognizer()
    private var trackingSince: TimeInterval?
    private var lastHandTime: TimeInterval?
    private var previousRatio: CGFloat?
    private var clickAnchor: ClickAnchor?
    var position: CGPoint? { filter.position }
    var pinchStatus: String {
        if clickAnchor != nil && !pinch.held { return "Target held — touch fingertips to click" }
        switch pinch.phase {
        case .openToArm: return "Separate thumb and index to get ready"
        case .ready: return "Ready — touch thumb and index to click"
        case .closing: return "Contact detected — keep touching briefly"
        case .release: return "Clicked — separate fingers for the next click"
        case .unclear: return "Keep thumb and index visible to the camera"
        }
    }

    mutating func reset() {
        filter.reset()
        pinch.reset()
        trackingSince = nil
        lastHandTime = nil
        previousRatio = nil
        clickAnchor = nil
    }

    mutating func missing(time: TimeInterval) {
        pinch.reset()
        releaseAnchor()
        previousRatio = nil
        if time - (lastHandTime ?? 0) > 0.25 { trackingSince = nil }
    }

    mutating func uncertain(time: TimeInterval) {
        // A visible palm with unclear fingertips cannot move or click. Briefly retain
        // readiness, but cancel it if uncertainty persists beyond the fingertip grace.
        pinch.unavailable(time: time)
        if let anchor = clickAnchor, time - anchor.progressedAt > 0.22 { releaseAnchor() }
        if time - (lastHandTime ?? 0) > 0.35 { trackingSince = nil }
    }

    private mutating func releaseAnchor() {
        if let anchor = clickAnchor { filter.reset(seed: anchor.position) }
        clickAnchor = nil
    }

    mutating func update(target: CGPoint, pinchRatio: CGFloat?, time: TimeInterval,
                         currentCursor: CGPoint?) -> PointerDecision? {
        guard target.x.isFinite, target.y.isFinite else { missing(time: time); return nil }
        if lastHandTime == nil || time - lastHandTime! > 0.25 {
            filter.reset(seed: currentCursor)
            trackingSince = time
            pinch.reset()
            previousRatio = nil
            clickAnchor = nil
        }
        lastHandTime = time
        if trackingSince == nil { trackingSince = time }
        guard time - trackingSince! >= 0.10 else { return nil }
        let wasReady = pinch.armed
        let wasClosing = pinch.phase == .closing
        let click: Bool
        if let ratio = pinchRatio {
            click = pinch.update(ratio: ratio, time: time)
        } else {
            pinch.unavailable(time: time)
            click = false
        }

        if var anchor = clickAnchor {
            var cancelled = false
            if let clickedAt = anchor.clickedAt {
                cancelled = time - clickedAt >= 0.18 || (pinchRatio ?? 0) >= 0.60
            } else if time - anchor.startedAt > 0.65 {
                cancelled = true
            } else if let ratio = pinchRatio {
                if ratio < anchor.lowestRatio - 0.02 { anchor.progressedAt = time }
                cancelled = ratio > anchor.lowestRatio + 0.15 ||
                    (ratio > 0.38 && time - anchor.progressedAt > 0.14)
                anchor.lowestRatio = min(anchor.lowestRatio, ratio)
            } else {
                cancelled = time - anchor.progressedAt > 0.22
            }
            clickAnchor = anchor
            if cancelled { releaseAnchor() }
        }

        if clickAnchor == nil {
            let closingTrend: Bool
            if let ratio = pinchRatio, let previous = previousRatio {
                closingTrend = wasReady && previous - ratio >= 0.04
            } else {
                closingTrend = wasReady && previousRatio != nil && pinchRatio == nil
            }
            let contactStarted = pinch.phase == .closing && !wasClosing
            if closingTrend || contactStarted || click {
                clickAnchor = ClickAnchor(position: filter.position ?? currentCursor ?? target,
                    startedAt: time, lowestRatio: pinchRatio ?? previousRatio ?? 1,
                    progressedAt: time, clickedAt: nil)
            }
        }
        if click { clickAnchor?.clickedAt = time }
        previousRatio = pinchRatio
        let holding = clickAnchor != nil || pinchRatio.map {
            pinch.shouldHoldPointer(ratio: $0, time: time)
        } == true
        let position: CGPoint
        if let anchor = clickAnchor {
            position = anchor.position
        } else if holding, let current = filter.position {
            position = current
        } else {
            position = filter.update(target: target, time: time)
        }
        return PointerDecision(position: position, click: click, holding: holding)
    }
}

/// Fist recognition uses non-thumb fingers so a thumb/index pinch stays a click.
enum FingerPosture {
    case curled, extended, unclear
    static func classify(tip: CGPoint, pip: CGPoint, mcp: CGPoint, wrist: CGPoint) -> FingerPosture {
        func d(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
        let scale = d(mcp, wrist)
        guard scale > 0.015 else { return .unclear }
        if d(tip, wrist) < d(pip, wrist) * 1.12 && d(tip, mcp) < scale * 0.85 { return .curled }
        if d(tip, wrist) > d(pip, wrist) * 1.22 { return .extended }
        return .unclear
    }
}

struct FistGate {
    private(set) var paused = false
    private var openSince: TimeInterval?
    mutating func update(_ fingers: [FingerPosture], time: TimeInterval) -> Bool {
        if fingers.filter({ $0 == .curled }).count >= 3 {
            paused = true
            openSince = nil
        } else if paused && fingers.filter({ $0 == .extended }).count >= 2 {
            if openSince == nil { openSince = time }
            if time - openSince! >= 0.15 { paused = false; openSince = nil }
        } else { openSince = nil }
        return paused
    }
}

/// Rebases after a clutch, preserving the reached cursor position on release.
struct PointerClutch {
    private(set) var paused = false
    private var needsRebase = false
    private var offset = CGPoint.zero
    mutating func setPaused(_ value: Bool) {
        if paused && !value { needsRebase = true }
        paused = value
    }
    mutating func target(_ input: CGPoint, cursor: CGPoint, bounds: CGRect) -> CGPoint? {
        guard !paused else { return nil }
        if needsRebase {
            offset = CGPoint(x: cursor.x - input.x, y: cursor.y - input.y)
            needsRebase = false
        }
        let output = CGPoint(x: min(max(input.x + offset.x, bounds.minX), bounds.maxX - 1),
                             y: min(max(input.y + offset.y, bounds.minY), bounds.maxY - 1))
        // Consume overshoot so reversing at a screen edge responds immediately.
        offset = CGPoint(x: output.x - input.x, y: output.y - input.y)
        return output
    }
}
