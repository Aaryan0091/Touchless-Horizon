import AppKit
import ApplicationServices

/// Use the player's labelled control so repeated pause never starts playback.
enum MediaPlayback {
    static func perform(_ command: String) -> String {
        guard let app = NSWorkspace.shared.frontmostApplication else { return "Select YouTube or Spotify first" }
        guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return "Select YouTube or Spotify, then say “\(command)”" }
        let spotify = app.bundleIdentifier == "com.spotify.client"
        let root = AXUIElementCreateApplication(app.processIdentifier)
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
            return value
        }
        guard let window = attribute(root, kAXFocusedWindowAttribute) else { return "No player window selected" }
        let windowElement = window as! AXUIElement
        let title = attribute(windowElement, kAXTitleAttribute) as? String ?? ""
        guard spotify || title.localizedCaseInsensitiveContains("youtube") else {
            return "Select a YouTube video or the Spotify player first"
        }
        var queue: [(element: AXUIElement, player: Bool)] = [(windowElement, !spotify)]
        var index = 0
        var oppositeFound = false
        while index < queue.count && index < 4000 {
            let item = queue[index]
            let element = item.element
            index += 1
            let names = [kAXTitleAttribute, kAXDescriptionAttribute].compactMap { attribute(element, $0) as? String }
            let inPlayer = item.player || names.contains(where: { $0.lowercased() == "player controls" })
            let role = attribute(element, kAXRoleAttribute) as? String
            if inPlayer && role == kAXButtonRole {
                let labels = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute].compactMap {
                    attribute(element, $0) as? String
                }
                for label in labels {
                    guard let action = PlaybackButtonAction.from(label) else { continue }
                    if action.shouldPress(for: command) {
                        guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else {
                            return "Player control unavailable — click the player once and retry"
                        }
                        return command == "pause" ? "Media paused" : "Media resumed"
                    }
                    oppositeFound = true
                }
            }
            if let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
                queue.append(contentsOf: children.prefix(max(0, 4000 - queue.count)).map { ($0, inPlayer) })
            }
        }
        if oppositeFound { return command == "pause" ? "Media already paused" : "Media already playing" }
        return "Player controls not found — open a video or track and retry"
    }
}
