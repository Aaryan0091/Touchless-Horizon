# Verification — 2 November 2026

## Current automated checks

- `./test-gestures.sh`: 1,273 checks pass. These include repeated frames/scenarios; the count does not represent 1,273 separately tested product features.
- Direct optimized app compilation succeeds.
- `codesign --verify --deep "Touchless Horizon.app"` succeeds (local ad-hoc signature).
- Pure logic covers coordinate directions, reversal/re-entry, smoothing, pinch arming/release/debounce/anchoring, uncertain landmarks, fist clutch/rebasing, independent voice pause, command capitalization/deduplication, transcript replacement, silence clearing, playback label decisions, and multiword phrase settling.

## Fixes during this review

- Wait for a phrase to settle before executing it, preventing a partial “pause gestures” from dispatching the shorter media “pause” command. Final results can dispatch immediately.
- Double-click sends mouse click-state metadata 1 then 2.
- Corrected the README's obsolete Resume description.

## Runtime observations

- Updated app launches and its main controls are exposed.
- Existing system-control permission restored and app reports enabled.
- Camera reaches active state at 1280 × 720. Voice reaches Listening with live microphone level updates.
- Ordinary practice button click increments counter from 0 to 1. This is not evidence of a camera pinch.
- Hover clicks and air swipes remain off by default.

## Earlier live user confirmations

These predate this review's build and are not a substitute for current end-to-end testing:

- Fist pause/reposition/resume worked.
- Transcript cleared after silence and subsequent speech started fresh.
- Window remained open instead of auto-hiding.
- YouTube pause worked; resume worked on a later attempt. Recognition changes have since addressed a reproduced transcript-filter issue.

## Limits and outstanding live checks

- This review cannot certify all real hand/voice behavior from deterministic tests. Current-build pointing, pinch, fist, speech, media, zoom and navigation need live user input.
- Hover/dwell, air swipes, double-click behavior in a target app, open/close, app switching and theme have not all been verified end-to-end in this review.
- Pointer mapping currently targets the main display.
- Media commands require the selected Spotify window or YouTube video tab and English-labelled accessible player controls. This is not a universal media controller.
- Zoom/navigation/open/close use target-app keyboard shortcuts; support varies by app.
- Theme change needs macOS Automation permission; other protected apps may reject generated input.
- Playback success text records a successful accessibility press; it does not independently measure video/audio playback.
- Microphone recognition can include nearby playback; there is no speaker authentication or echo cancellation guarantee.
- Local source changes have not been committed or pushed by this review.

## Safari resume follow-up

The failing live state showed “Player controls not found.” Safari exposed the paused player as “Play keyboard shortcut k,” a label the matcher did not accept. Added this exact label form (and its Pause counterpart); the reproduction test failed before the fix and passes after it. Rebuilt, verified signature, restored existing control permission, and started voice. User confirmed the rebuilt app resumes the paused YouTube video in the live test. Capitalization normalization remains covered independently.
