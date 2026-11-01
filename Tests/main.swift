import Foundation
import CoreGraphics

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    checks += 1
}

let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
let highHand = GestureGeometry.screenPoint(CGPoint(x: 0.5, y: 0.8), bounds: screen)
let lowHand = GestureGeometry.screenPoint(CGPoint(x: 0.5, y: 0.2), bounds: screen)
check(lowHand.y > highHand.y, "Lowering the hand must move the pointer down")
check(GestureGeometry.screenPoint(CGPoint(x: 0.2, y: 0.5), bounds: screen).x > 720,
      "Horizontal camera movement remains mirrored")
check(GestureGeometry.screenPoint(CGPoint(x: -0.1, y: 1.1), bounds: screen) == CGPoint(x: 1440, y: 0),
      "Off-frame landmarks cannot move outside the screen")

var pinch = PinchRecognizer()
for i in 0..<100 {
    check(!pinch.update(ratio: 0.1, time: Double(i) / 30),
          "A hand acquired already pinched must never click")
}
pinch.reset()
check(!pinch.update(ratio: 1, time: 4), "Opening fingers must not click")
check(!pinch.update(ratio: 1, time: 4.2), "Opening arms the next deliberate pinch")
check(pinch.armed, "Stable separated fingers arm pinch detection")
check(!pinch.shouldHoldPointer(ratio: 0.45, time: 4.25), "Nearby fingers without contact must not freeze movement")
check(!pinch.update(ratio: 0.2, time: 4.3), "One closed frame must not click")
check(!pinch.update(ratio: 0.5, time: 4.34), "A noisy closed frame must be rejected")
check(!pinch.update(ratio: 0.2, time: 4.4), "A new candidate must debounce again")
check(pinch.shouldHoldPointer(ratio: 0.2, time: 4.4), "Hold the pointer briefly during a real closing candidate")
check(pinch.update(ratio: 0.2, time: 4.54), "A stable deliberate pinch clicks once")
check(!pinch.shouldHoldPointer(ratio: 0.2, time: 4.8), "A held pinch must not lock pointer movement indefinitely")
for i in 0..<100 {
    check(!pinch.update(ratio: 0.2, time: 4.6 + Double(i) / 30),
          "Holding a pinch must not repeat clicks")
}
check(!pinch.update(ratio: 0.6, time: 8), "A partial release must not rearm")
check(!pinch.update(ratio: 0.2, time: 8.2), "Partial release plus close must not click")
check(!pinch.update(ratio: 1, time: 8.4), "Release starts a new arm interval")
check(!pinch.update(ratio: 1, time: 8.6), "Release finishes the arm interval")
check(!pinch.update(ratio: 0.2, time: 8.7), "Second pinch starts debounce")
check(pinch.update(ratio: 0.2, time: 8.84), "Release enables a second intentional click")
pinch.reset()
check(!pinch.update(ratio: 0.2, time: 10), "Tracking loss cancels pinch arming")
check(!pinch.update(ratio: .nan, time: 10.2), "Invalid geometry cannot click")

var relaxed = PinchRecognizer()
_ = relaxed.update(ratio: 1, time: -1)
_ = relaxed.update(ratio: 1, time: -0.7)
for i in 0..<300 {
    let ratio: CGFloat = i % 2 == 0 ? 0.45 : 0.60
    check(!relaxed.update(ratio: ratio, time: Double(i) / 30),
          "Relaxed fingers near the previous threshold cannot trigger a click")
}

var filter = CursorFilter()
filter.reset(seed: CGPoint(x: 100, y: 100))
for i in 0..<30 { _ = filter.update(target: CGPoint(x: 100, y: 100), time: Double(i) / 30) }
let rejected = filter.update(target: CGPoint(x: 1300, y: 800), time: 1)
check(rejected == CGPoint(x: 100, y: 100), "An isolated bad landmark must not jump the cursor")
_ = filter.update(target: CGPoint(x: 100, y: 100), time: 1.034)
for i in 0..<60 {
    let jitter: CGFloat = i % 2 == 0 ? 1 : -1
    let point = filter.update(target: CGPoint(x: 100 + jitter, y: 100 - jitter), time: 1.1 + Double(i) / 30)
    check(hypot(point.x - 100, point.y - 100) < 2.5, "Small camera noise should not move the pointer")
}
for i in 0..<30 {
    _ = filter.update(target: CGPoint(x: 500, y: 500), time: 3.2 + Double(i) / 30)
}
check(hypot(filter.position!.x - 500, filter.position!.y - 500) < 8,
      "Smoothing must still follow sustained intentional movement")

var noisy = CursorFilter()
noisy.reset(seed: CGPoint(x: 500, y: 400))
let noise: [CGFloat] = [18, -14, 8, -20, 13, -9, 5, 0, -3, 7]
var rawNoise: Double = 0
var filteredNoise: Double = 0
for i in 0..<300 {
    let point = noisy.update(target: CGPoint(x: 500 + noise[i % noise.count], y: 400 + noise[(i + 4) % noise.count]),
                             time: Double(i) / 30)
    check(hypot(point.x - 500, point.y - 400) < 14,
          "Moderate landmark shaking must be substantially damped")
    rawNoise += Double(pow(noise[i % noise.count], 2) + pow(noise[(i + 4) % noise.count], 2))
    filteredNoise += Double(pow(point.x - 500, 2) + pow(point.y - 400, 2))
}
check(filteredNoise < rawNoise * 0.20, "Filtering must remove most of the simulated shake energy")
print("Simulated pointer shake reduced by \(Int((1 - sqrt(filteredNoise / rawNoise)) * 100))% RMS")
var burst = CursorFilter()
for i in 0..<30 { _ = burst.update(target: CGPoint(x: 100, y: 100), time: Double(i) / 30) }
for i in 0..<3 {
    let point = burst.update(target: CGPoint(x: 1100, y: 700), time: 1 + Double(i) / 30)
    check(hypot(point.x - 100, point.y - 100) <= 58,
          "Even a burst of distant landmarks must respect the pointer speed limit")
}
for i in 0..<40 { _ = burst.update(target: CGPoint(x: 100, y: 100), time: 1.1 + Double(i) / 30) }
check(hypot(burst.position!.x - 100, burst.position!.y - 100) < 8,
      "Returning from bad landmarks must recover without a permanent lock")

var reversing = CursorFilter()
for i in 0..<30 { _ = reversing.update(target: CGPoint(x: 40, y: 450), time: Double(i) / 30) }
let leftEdge = reversing.position!.x
for i in 1...10 {
    _ = reversing.update(target: CGPoint(x: 40 + CGFloat(i) * 130, y: 450), time: 1 + Double(i) / 30)
}
check(reversing.position!.x > leftEdge + 200,
      "Continuous rightward motion must leave the left edge instead of being rejected forever")
for i in 0..<30 { _ = reversing.update(target: CGPoint(x: 1340, y: 450), time: 1.4 + Double(i) / 30) }
let rightEdge = reversing.position!.x
for i in 1...10 {
    _ = reversing.update(target: CGPoint(x: 1340 - CGFloat(i) * 130, y: 450), time: 2.5 + Double(i) / 30)
}
check(reversing.position!.x < rightEdge - 200,
      "Continuous leftward motion must leave the right edge")

for fps in [15, 30, 60] {
    var engine = GesturePointerEngine()
    var cursor = CGPoint(x: 720, y: 450)
    var time: TimeInterval = 0
    var clickCount = 0
    func frame(_ target: CGPoint, ratio: CGFloat?) {
        if let decision = engine.update(target: target, pinchRatio: ratio, time: time, currentCursor: cursor) {
            cursor = decision.position
            if decision.click { clickCount += 1 }
        }
        time += 1.0 / Double(fps)
    }
    for _ in 0..<fps { frame(cursor, ratio: 1) }
    for i in 1...fps {
        frame(CGPoint(x: 720 - CGFloat(i) * 680 / CGFloat(fps), y: 450), ratio: 0.45)
    }
    check(cursor.x < 200, "\(fps) FPS: relaxed fingers allow movement to the left")
    for i in 1...(fps * 2) {
        let x = min(40 + CGFloat(i) * 1300 / CGFloat(fps), 1340)
        frame(CGPoint(x: x, y: 450), ratio: 0.45)
    }
    check(cursor.x > 1300, "\(fps) FPS: the integrated pointer reverses from left to right")
    for _ in 0..<fps {
        engine.missing(time: time)
        time += 1.0 / Double(fps)
    }
    for _ in 0..<(fps * 2) { frame(CGPoint(x: 720, y: 450), ratio: 0.2) }
    check(abs(cursor.x - 720) < 8, "\(fps) FPS: hand re-entry recovers from the edge")
    check(clickCount == 0, "\(fps) FPS: nearby fingers and pinched re-entry never click")
    for _ in 0..<fps { frame(CGPoint(x: 720, y: 450), ratio: 1) }
    for _ in 0..<(fps * 2) { frame(CGPoint(x: 40, y: 450), ratio: 0.2) }
    check(clickCount == 1, "\(fps) FPS: a deliberate pinch clicks once")
    check(cursor.x < 80, "\(fps) FPS: a held pinch cannot trap the cursor on the right")
}

let uncertainPalm = GestureGeometry.pinchRatio(index: .zero, thumb: .zero,
    indexMCP: .zero, littleMCP: CGPoint(x: 0.01, y: 0), imageAspect: 0.75)
check(uncertainPalm == nil, "Too-small hand geometry must not enable clicks")

var occluded = GesturePointerEngine()
for i in 0..<30 {
    _ = occluded.update(target: CGPoint(x: 500, y: 400), pinchRatio: 1,
                        time: Double(i) / 30, currentCursor: CGPoint(x: 500, y: 400))
}
_ = occluded.update(target: CGPoint(x: 500, y: 400), pinchRatio: nil,
                    time: 1, currentCursor: CGPoint(x: 500, y: 400))
var contactClicks = 0
for i in 0..<8 {
    let decision = occluded.update(target: CGPoint(x: 500, y: 400), pinchRatio: 0.20,
        time: 1.04 + Double(i) / 30, currentCursor: CGPoint(x: 500, y: 400))
    if decision?.click == true { contactClicks += 1 }
}
check(contactClicks == 1, "Brief fingertip occlusion with the hand still tracked must not cancel a deliberate pinch")

var quick = PinchRecognizer()
_ = quick.update(ratio: 0.9, time: 0)
_ = quick.update(ratio: 0.9, time: 0.15)
check(!quick.update(ratio: 0.36, time: 0.2), "A single contact observation still cannot click")
check(quick.update(ratio: 0.36, time: 0.28), "Natural fingertip contact clicks without a long squeeze")
check(!quick.update(ratio: 0.36, time: 0.34), "The same contact does not click twice")

var longGap = GesturePointerEngine()
for i in 0..<30 {
    _ = longGap.update(target: .zero, pinchRatio: 1, time: Double(i) / 30, currentCursor: .zero)
}
for i in 0..<12 {
    _ = longGap.update(target: .zero, pinchRatio: nil, time: 1 + Double(i) / 30, currentCursor: .zero)
}
for i in 0..<20 {
    let result = longGap.update(target: .zero, pinchRatio: 0.2,
                               time: 1.4 + Double(i) / 30, currentCursor: .zero)
    check(result?.click != true, "Long fingertip loss must require opening again before a click")
}
let sideOnPalm = GestureGeometry.pinchRatio(index: CGPoint(x: 0.5, y: 0.7),
    thumb: CGPoint(x: 0.52, y: 0.7), indexMCP: nil, littleMCP: nil, imageAspect: 0.75,
    wrist: CGPoint(x: 0.5, y: 0.2), middleMCP: CGPoint(x: 0.5, y: 0.5))
check(sideOnPalm != nil && sideOnPalm! < 0.38,
      "Wrist-to-palm geometry supports contact when the palm's outside edge is occluded")

for fps in [15, 30, 60] {
    var aimed = GesturePointerEngine()
    let button = CGPoint(x: 500, y: 400)
    for i in 0..<fps {
        _ = aimed.update(target: button, pinchRatio: 1,
                         time: Double(i) / Double(fps), currentCursor: button)
    }
    var clickPoint: CGPoint?
    let closing: [CGFloat] = [0.90, 0.78, 0.66, 0.54, 0.44, 0.36, 0.25, 0.20, 0.20, 0.20]
    for (i, ratio) in closing.enumerated() {
        let result = aimed.update(target: CGPoint(x: 500 + CGFloat(i + 1) * 50, y: 400 + CGFloat(i + 1) * 20),
            pinchRatio: ratio, time: 1 + Double(i) / Double(fps), currentCursor: button)
        if result?.click == true { clickPoint = result?.position }
    }
    check(clickPoint != nil, "\(fps) FPS: a closing pinch still produces a click")
    check(hypot(clickPoint!.x - button.x, clickPoint!.y - button.y) < 1,
          "\(fps) FPS: finger motion during closure must not move the click off the aimed button")
}

var abandoned = GesturePointerEngine()
let origin = CGPoint(x: 300, y: 300)
for i in 0..<30 { _ = abandoned.update(target: origin, pinchRatio: 1, time: Double(i) / 30, currentCursor: origin) }
_ = abandoned.update(target: CGPoint(x: 380, y: 330), pinchRatio: 0.8, time: 1, currentCursor: origin)
for i in 0..<60 {
    let result = abandoned.update(target: CGPoint(x: 1100, y: 500), pinchRatio: 1,
                                  time: 1.04 + Double(i) / 30, currentCursor: origin)
    check(result?.click != true, "Abandoning an approaching pinch cannot click")
}
check(abandoned.position!.x > 1080, "Abandoning a pinch releases the anchor and allows movement")

var occludedAim = GesturePointerEngine()
for i in 0..<30 { _ = occludedAim.update(target: origin, pinchRatio: 1, time: Double(i) / 30, currentCursor: origin) }
_ = occludedAim.update(target: CGPoint(x: 350, y: 330), pinchRatio: 0.8, time: 1, currentCursor: origin)
_ = occludedAim.update(target: CGPoint(x: 450, y: 380), pinchRatio: nil, time: 1.04, currentCursor: origin)
var anchoredContact: CGPoint?
for i in 0..<5 {
    let result = occludedAim.update(target: CGPoint(x: 550, y: 420), pinchRatio: 0.2,
        time: 1.08 + Double(i) / 30, currentCursor: origin)
    if result?.click == true { anchoredContact = result?.position }
}
check(anchoredContact == origin, "Fingertip occlusion during closure must preserve the chosen click target")

let withoutWrist = HandTrackingGeometry.palmAnchor([
    HandLandmark(point: CGPoint(x: 0.4, y: 0.4), confidence: 0.7),
    HandLandmark(point: CGPoint(x: 0.5, y: 0.4), confidence: 0.6),
    HandLandmark(point: CGPoint(x: 0.6, y: 0.4), confidence: 0.4)
])
check(withoutWrist != nil, "Visible palm joints retain the hand without a wrist landmark")
check(HandTrackingGeometry.palmAnchor([HandLandmark(point: .zero, confidence: 0.1)]) == nil,
      "A single weak joint cannot acquire a hand")

var gate = HandTrackingGate()
check(gate.update(palmVisible: false, indexConfidence: nil, time: 0) == .lost,
      "No hand at startup is reported as lost")
check(gate.update(palmVisible: true, indexConfidence: 0.25, time: 0.1) == .fingertipsUnclear,
      "Acquisition still requires a usable fingertip")
check(gate.update(palmVisible: true, indexConfidence: 0.34, time: 0.2) == .tracked,
      "A visible palm and usable index acquire tracking")
check(gate.update(palmVisible: true, indexConfidence: 0.21, time: 0.23) == .tracked,
      "One weaker index frame does not discard an established hand")
check(gate.update(palmVisible: true, indexConfidence: nil, time: 0.26) == .fingertipsUnclear,
      "Visible palm with missing fingertip is distinguished from losing the hand")
check(gate.update(palmVisible: false, indexConfidence: nil, time: 0.3) == .brieflyMissing,
      "A short detector gap holds position rather than flashing lost")
check(gate.update(palmVisible: false, indexConfidence: nil, time: 0.7) == .lost,
      "A genuinely absent hand expires the tracking grace")
check(gate.update(palmVisible: true, indexConfidence: 0.2, time: 0.9) == .fingertipsUnclear,
      "Reacquiring after a long loss requires the stronger threshold again")
check(gate.update(palmVisible: true, indexConfidence: 0.4, time: 1) == .tracked,
      "Tracking recovers when the fingertip becomes clear")
for i in 1...120 {
    let state = gate.update(palmVisible: i % 15 != 0, indexConfidence: 0.22, time: 1 + Double(i) / 30)
    check(state == .tracked || state == .brieflyMissing, "Intermittent weak frames must not repeatedly discard a hand")
}

var paused = GesturePointerEngine()
for i in 0..<30 { _ = paused.update(target: origin, pinchRatio: 1, time: Double(i) / 30, currentCursor: origin) }
paused.uncertain(time: 1)
paused.uncertain(time: 1.04)
check(paused.position == origin, "Uncertain frames never move the pointer")
var recoveredClicks = 0
for i in 0..<6 {
    let result = paused.update(target: origin, pinchRatio: 0.2, time: 1.08 + Double(i) / 30, currentCursor: origin)
    if result?.click == true { recoveredClicks += 1 }
}
check(recoveredClicks == 1, "A brief partial-hand gap can recover an intentional pinch")
for i in 0..<30 { paused.uncertain(time: 1.4 + Double(i) / 30) }
for i in 0..<15 {
    let result = paused.update(target: origin, pinchRatio: 0.2, time: 2.5 + Double(i) / 30, currentCursor: origin)
    check(result?.click != true, "Sustained uncertain tracking cannot create a click on recovery")
}
// Fist clutch: stable release, no pinch confusion, and relative repositioning.
var fist = FistGate()
check(!fist.update([.curled, .extended, .extended, .extended], time: 0), "Index pinch alone cannot pause tracking")
check(fist.update([.curled, .curled, .curled, .unclear], time: 0.1), "Three curled fingers pause immediately")
check(fist.update([], time: 1), "Missing landmarks cannot release a fist pause")
check(fist.update([.extended, .extended], time: 1.1), "One open frame cannot accidentally resume")
check(fist.update([], time: 1.2), "Uncertainty restarts the open-hand confirmation")
check(fist.update([.extended, .extended, .extended], time: 1.3), "Open hand begins release confirmation")
check(!fist.update([.extended, .extended, .extended], time: 1.5), "Sustained open hand resumes")
let wristPoint = CGPoint(x: 0.5, y: 0.2)
check(FingerPosture.classify(tip: CGPoint(x: 0.5, y: 0.4), pip: CGPoint(x: 0.5, y: 0.51), mcp: CGPoint(x: 0.5, y: 0.43), wrist: wristPoint) == .curled, "Folded fingertip is recognized")
check(FingerPosture.classify(tip: CGPoint(x: 0.5, y: 0.8), pip: CGPoint(x: 0.5, y: 0.6), mcp: CGPoint(x: 0.5, y: 0.43), wrist: wristPoint) == .extended, "Straight finger is recognized")
var clutch = PointerClutch()
let reached = CGPoint(x: 800, y: 500)
clutch.setPaused(true)
check(clutch.target(.zero, cursor: reached, bounds: screen) == nil, "Closed fist sends no pointer target")
clutch.setPaused(false)
check(clutch.target(CGPoint(x: 300, y: 300), cursor: reached, bounds: screen) == reached, "Opening at a new hand position preserves reached cursor position")
check(clutch.target(CGPoint(x: 350, y: 320), cursor: reached, bounds: screen) == CGPoint(x: 850, y: 520), "Movement after release follows relative hand motion")
_ = clutch.target(CGPoint(x: 1400, y: 320), cursor: reached, bounds: screen)
check(clutch.target(CGPoint(x: 1380, y: 320), cursor: reached, bounds: screen)?.x == screen.maxX - 21, "Reversal at the edge is immediate after clutching")
clutch.setPaused(true)
clutch.setPaused(false)
check(clutch.target(CGPoint(x: 100, y: 100), cursor: reached, bounds: screen) == reached, "Repeated clutch cycles preserve the actual cursor")
var voiceGate = VoiceCommandGate()
let voiceCommands = ["zoom in", "zoom out", "click"]
let zoomIn = [VoiceWord(text: "Zoom", start: 0.5, duration: 0.3), VoiceWord(text: "in", start: 0.8, duration: 0.2)]
check(voiceGate.command(in: zoomIn, commands: voiceCommands) == "zoom in", "One spoken zoom triggers once")
for _ in 0..<50 {
    check(voiceGate.command(in: zoomIn, commands: voiceCommands) == nil, "Repeated partial or final results never repeat consumed audio")
}
let revised = [VoiceWord(text: "Touchless Horizon", start: 0, duration: 0.4)] + zoomIn
check(voiceGate.command(in: revised, commands: voiceCommands) == nil, "Revised prefix cannot replay the command")
let changed = [VoiceWord(text: "zoom", start: 0.51, duration: 0.3), VoiceWord(text: "out", start: 0.81, duration: 0.3)]
check(voiceGate.command(in: changed, commands: voiceCommands) == nil, "Correction of consumed audio cannot execute a second action")
let twice = zoomIn + [VoiceWord(text: "zoom", start: 1.2, duration: 0.3), VoiceWord(text: "in", start: 1.5, duration: 0.2)]
check(voiceGate.command(in: twice, commands: voiceCommands) == "zoom in", "A genuinely repeated command with new audio still works")
check(voiceGate.command(in: twice, commands: voiceCommands) == nil, "Final result after intentional repeat is suppressed")
let out = twice + [VoiceWord(text: "zoom", start: 2, duration: 0.3), VoiceWord(text: "out", start: 2.3, duration: 0.2)]
check(voiceGate.command(in: out, commands: voiceCommands) == "zoom out", "Opposite command on new audio works")
voiceGate = VoiceCommandGate()
check(voiceGate.command(in: zoomIn, commands: voiceCommands) == "zoom in", "New recognition session accepts new audio timestamps")
var provisional = VoiceCommandGate()
let untimed = [VoiceWord(text: "zoom", start: 0, duration: 0), VoiceWord(text: "in", start: 0, duration: 0)]
check(provisional.command(in: untimed, commands: voiceCommands) == "zoom in", "Untimed partial transcript still triggers")
check(provisional.command(in: zoomIn, commands: voiceCommands) == nil, "Final timestamps cannot replay an untimed partial")
check(provisional.command(in: untimed + untimed, commands: voiceCommands) == "zoom in", "New words allow repeated commands before timestamps finalize")
var silence = VoiceSilenceBoundary()
check(!silence.shouldRefresh(time: 100), "Silence before any words does not restart recognition")
silence.heard("zoom in", time: 100)
silence.audio(level: 0.06, time: 101)
check(!silence.shouldRefresh(time: 101), "Short pauses within speech keep context")
check(silence.shouldRefresh(time: 101.5), "Quiet after recognized words requests a fresh session")
silence.audio(level: 0.3, time: 101.5)
check(!silence.shouldRefresh(time: 102), "Continued speech postpones clearing")
silence.heard("zoom in", time: 102)
check(silence.shouldRefresh(time: 103), "Repeated unchanged recognition callbacks do not extend old words")
silence.heard("zoom in zoom out", time: 103)
check(!silence.shouldRefresh(time: 104), "New words extend the utterance")
check(silence.shouldRefresh(time: 104.5), "A new pause clears the completed utterance")
silence = VoiceSilenceBoundary()
check(!silence.shouldRefresh(time: 200), "Fresh session has no stale transcript")
for spelling in ["pause", "Pause", "PAUSE", "pAuSe", "resume", "Resume", "RESUME", "ReSuMe"] {
    var parser = VoiceCommandGate()
    check(parser.command(in: [VoiceWord(text: spelling, start: 1, duration: 0.3)], commands: ["pause", "resume"]) == spelling.lowercased(), "Pause and resume ignore all capitalization")
}
var pauseState = GesturePauseState()
pauseState.pause()
check(pauseState.paused, "Voice pause holds gestures")
pauseState.setFist(false)
check(pauseState.paused, "Opening hand cannot undo voice pause")
pauseState.setFist(true)
pauseState.resume()
check(!pauseState.paused, "Voice resume clears both voice and fist pause")
pauseState.resume()
check(!pauseState.paused, "Repeated resume does not toggle gestures off")
pauseState.pause()
pauseState.pause()
check(pauseState.paused, "Repeated pause stays paused")
var commandSequence = VoiceCommandGate()
let pauseWords = [VoiceWord(text: "Pause", start: 1, duration: 0.3)]
check(commandSequence.command(in: pauseWords, commands: ["pause", "resume"]) == "pause", "Pause recognition executes")
check(commandSequence.command(in: pauseWords, commands: ["pause", "resume"]) == nil, "Partial/final pause is not repeated")
check(commandSequence.command(in: pauseWords + [VoiceWord(text: "RESUME", start: 2, duration: 0.4)], commands: ["pause", "resume"]) == "resume", "Resume after pause in the same transcript executes")
check(PlaybackButtonAction.from("Pause (k)") == .pause, "YouTube pause control recognized")
check(PlaybackButtonAction.from("Play (k)") == .play, "YouTube play control recognized")
check(PlaybackButtonAction.from("Pause") == .pause, "Spotify pause control recognized")
check(PlaybackButtonAction.from("PLAY") == .play, "Playback labels ignore capitalization")
check(PlaybackButtonAction.from("Play playlist") == nil, "Playlist buttons cannot be confused with the player")
check(PlaybackButtonAction.from("Play/Pause") == nil, "Ambiguous toggles cannot invert a repeated pause")
check(PlaybackButtonAction.pause.shouldPress(for: "pause"), "Pause presses the pause control")
check(!PlaybackButtonAction.play.shouldPress(for: "pause"), "Pause never presses play on already paused media")
check(PlaybackButtonAction.play.shouldPress(for: "resume"), "Resume presses play")
check(!PlaybackButtonAction.pause.shouldPress(for: "resume"), "Resume never pauses already playing media")
for phrase in ["pause gestures", "resume gestures", "pause", "resume"] {
    var gate = VoiceCommandGate()
    check(gate.command(in: [VoiceWord(text: phrase, start: 1, duration: 1)], commands: ["pause gestures", "resume gestures", "pause", "resume"]) == phrase, "Media and gesture commands remain distinct")
}
var replacementGate = VoiceCommandGate()
check(replacementGate.command(in: [VoiceWord(text: "Pause", start: 1, duration: 0.4)], commands: ["pause", "resume"]) == "pause", "First media command runs")
check(replacementGate.command(in: [VoiceWord(text: "Resume", start: 3, duration: 0.5)], commands: ["pause", "resume"]) == "resume", "New audio may replace rather than append the old transcript")
var settled = SpeechUtteranceSettler()
settled.update(phrase: "pause", words: [VoiceWord(text: "pause", start: 1, duration: 0.2)], time: 0)
check(settled.takeReady(time: 0.2) == nil, "Partial pause waits for a possible gestures suffix")
settled.update(phrase: "pause gestures", words: [VoiceWord(text: "pause gestures", start: 1, duration: 0.6)], time: 0.3)
check(settled.takeReady(time: 0.6) == nil, "New words extend settling window")
var settledGate = VoiceCommandGate()
let stableWords = settled.takeReady(time: 0.9)!
check(settledGate.command(in: stableWords, commands: ["pause gestures", "pause"]) == "pause gestures", "Full gesture command executes instead of media prefix")
check(settled.takeReady(time: 1.5) == nil, "Settled phrase emits only once")
settled.update(phrase: "Pause Gestures", words: stableWords, time: 2)
check(settled.takeReady(time: 3) == nil, "Capitalization-only updates do not replay commands")
settled.update(phrase: "resume", words: [VoiceWord(text: "resume", start: 3, duration: 0.5)], time: 3)
check(settled.takeReady(time: 3.1, final: true)?.first?.text == "resume", "Final recognition can execute without added delay")
check(PlaybackButtonAction.from("Play keyboard shortcut k") == .play, "Safari paused YouTube label supports resume")
check(PlaybackButtonAction.from("Pause keyboard shortcut k") == .pause, "Safari playing YouTube label supports pause")
check(PlaybackButtonAction.from("Play next video") == nil, "Do not match unrelated Play-prefixed controls")
print("Passed \(checks) gesture regression checks")
