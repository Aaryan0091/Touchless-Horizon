# Touchless Horizon

Touchless Horizon is a macOS app for controlling other applications with a webcam and microphone. It does not depend on a website or a specific dashboard.

## Build and run

On this Mac, run `./build-app.sh` in this folder. Then open `Touchless Horizon.app` in Finder. The build script uses the installed Swift compiler and macOS 26.5 SDK because this machine's newest SDK and SwiftPM manifest libraries do not match its compiler.

Click **Start gestures** and/or **Start voice**. macOS will request Camera, Microphone, Speech Recognition, and system-control permissions. In **System Settings → Privacy & Security → Device Control and Data Access**, enable Touchless Horizon. If its switch is already on but the app still says **System control OFF**, switch it off and back on, then quit and reopen the app. A rebuilt local app can need its permission refreshed. Microphone and Speech Recognition are separate sections of Privacy & Security; both must be on for voice.

The camera preview shows the whole camera frame and its actual resolution. The app requests 1280 × 720 when supported and uses automatic exposure, focus, and white balance when available. Keep your full hand in the preview, with light from in front of you. Tracking uses multiple visible palm joints rather than requiring a clearly visible wrist, and it retains an established hand through weaker fingertip confidence. A short missing frame holds the pointer still; sustained absence is reported as lost. A visible palm with unclear fingertips pauses input until a usable fingertip returns. Uncertain frames never generate mouse movement or clicks.

For the most reliable voice result, say **“Touchless Horizon” followed by a command**, such as “Touchless Horizon next” or “Touchless Horizon help,” then pause briefly. Short commands alone are also accepted when the recognizer returns them. The window shows **Heard:** for the recognized words, **Mic signal** for input activity, and **Last action** when it executes a command.

If the control window is frontmost when you give a voice command, it hides itself and sends the command to the app behind it. Say “Touchless Horizon help” to bring the control window back. Commands such as **Next** and **Zoom in** follow the target app's own keyboard shortcuts, so their visible effect depends on the app.

## Controls

| Input | Action |
| --- | --- |
| Point with index finger | Move the system pointer |
| Separate thumb and index until **Pinch: Ready**, then touch their tips briefly | Click once; release before the next click |
| Hold the pointer still on an accessible button or link for 1.2 seconds | Optional: enable **Hover click** first; off by default |
| Open hand and swipe horizontally | Optional: enable **Air swipes** first; off by default |
| “Next” / “Previous” | Right/left arrow |
| “Zoom in” / “Zoom out” | Command-plus / Command-minus |
| “Scroll up” / “Scroll down” | Scroll focused app |
| “Click” / “Double click” | Click at the current pointer |
| “Open” / “Close” | Command-O / Command-W |
| “Switch app” | Command-Tab |
| “Toggle theme” | Toggle macOS appearance; may request Automation permission |
| “Help” | Show the control window |
| “Pause” | Stop gesture tracking; voice remains on |
| “Resume” | Start gesture tracking again |

Gestures and voice can be enabled together. For example, point at an image, then say “zoom in.” The target app decides how its keyboard shortcuts behave. Some protected windows and apps do not accept synthetic input, and dwell clicking depends on the app exposing accessible controls.

Keep your hand in view with the index finger extended. Moving the hand down moves the pointer down; horizontal motion is mirrored like a selfie camera. Pointer movement uses a median of three or five frames depending on frame rate, a small dead zone, and stronger damping for small movements. Every valid position enters the filter, and pointer speed is limited to prevent teleports without rejecting continuous movement. Tracking follows the same hand if a second hand enters the camera. A pinch requires separated fingers for 0.12 seconds, confirmed contact across at least two observations for 0.06 seconds, and release before another click. As the fingers approach, the engine captures the current pointer position and holds that target through the click, so closing the index finger cannot move the click off the chosen button. An abandoned closing motion releases the hold; a pending hold expires after 0.65 seconds and a completed click releases it within 0.18 seconds. Whole-hand tracking loss cancels readiness and the held target; brief loss of fingertip detail while the hand remains tracked preserves readiness for up to 0.22 seconds but cannot itself generate a click. Hover clicks and swipes start off so normal pointing does not trigger them.

The **Pinch** status line explains what the camera detects. Wait for **Ready**, aim, then touch thumb and index. **Target held** means the chosen position is locked for that click; **Clicked** means a click was sent. If it says **Keep thumb and index visible**, turn the palm slightly toward the camera and keep both fingertips in frame; wrist-to-palm geometry provides a fallback when the outside edge of the palm is hidden. The **Practice pinch click** button increments a counter so you can check aiming and click accuracy without changing any settings.

Run `./test-gestures.sh` to check coordinate direction, screen boundaries, pinch debouncing, release/rearm, tracking reset, jitter rejection, and intentional movement. These are deterministic logic checks; live pointing accuracy also depends on camera placement, lighting, and hand visibility.

The app processes camera frames locally with Apple's Vision hand pose API and uses Apple's Speech framework for command recognition. It prefers on-device recognition when available and falls back to Apple's speech service if on-device recognition fails. It does not save video, audio, or transcripts.

## Project files

- `Sources/main.swift`: app window, hand tracking, speech recognition, pointer and keyboard events.
- `Sources/GestureControl.swift`: coordinate mapping, cursor smoothing, and deliberate pinch recognition.
- `Tests/main.swift`: gesture regression checks without posting mouse or keyboard events.
- `Info.plist`: app metadata and permission descriptions.
- `build-app.sh`: standalone bundle build.

### Fist pause / reposition
Make a fist (at least three fingers curled) to hold the cursor and suppress gesture clicks, dwell, and swipes. Reposition your closed hand, then open at least two fingers for 0.15 seconds. Movement resumes relative to the cursor's current position; it does not return to the old absolute camera position. Missing landmarks keep the pause active. Separate thumb and index before the next pinch click.
