import Foundation

struct VoiceWord {
    let text: String
    let start: TimeInterval
    let duration: TimeInterval
}

/// Recognition updates revise the same audio repeatedly. Consume audio ranges,
/// rather than re-executing identical text after a wall-clock timeout.
struct VoiceCommandGate {
    private var consumedStart: TimeInterval?
    private var consumedEnd: TimeInterval = 0
    private var consumedWords = 0

    mutating func command(in words: [VoiceWord], commands: [String]) -> String? {
        let tokens = words.flatMap { word in
            word.text.lowercased().split(whereSeparator: { !$0.isLetter }).map {
                (text: String($0), start: word.start, end: word.start + word.duration)
            }
        }
        for command in commands {
            let parts = command.split(separator: " ").map(String.init)
            guard tokens.count >= parts.count else { continue }
            let suffix = Array(tokens.suffix(parts.count))
            guard suffix.map({ $0.text }) == parts, let first = suffix.first, let last = suffix.last else { continue }
            let newAudio = consumedStart.map {
                consumedEnd > $0 && first.start >= consumedEnd + 0.15
            } ?? false
            guard tokens.count > consumedWords || newAudio else { return nil }
            if let consumedStart, first.start > 0, last.end > first.start, consumedEnd > consumedStart {
                guard first.start > consumedStart + 0.05,
                      first.start >= consumedEnd - 0.03 else { return nil }
            }
            consumedWords = tokens.count
            consumedStart = first.start
            consumedEnd = max(first.start, last.end)
            return command
        }
        return nil
    }
}

/// Ends a transcript after a pause; idle silence never churns recognition tasks.
struct VoiceSilenceBoundary {
    private var phrase = ""
    private var lastActivity: TimeInterval?
    private(set) var hasWords = false
    let quietDuration: TimeInterval = 1.4

    mutating func heard(_ text: String, time: TimeInterval) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if text != phrase { lastActivity = time }
        phrase = text
        hasWords = true
    }

    mutating func audio(level: Double, time: TimeInterval) {
        // The UI meter is RMS amplified by eight. Ignore normal low-level room noise.
        if level >= 0.16 { lastActivity = time }
    }

    func shouldRefresh(time: TimeInterval) -> Bool {
        guard hasWords, let lastActivity else { return false }
        return time - lastActivity >= quietDuration
    }
}

/// Player buttons describe the action they would perform, not the current state.
enum PlaybackButtonAction: Equatable {
    case play, pause
    static func from(_ label: String) -> PlaybackButtonAction? {
        let text = label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "pause" || text.hasPrefix("pause (") || text.hasPrefix("pause keyboard shortcut ") { return .pause }
        if text == "play" || text.hasPrefix("play (") || text.hasPrefix("play keyboard shortcut ") { return .play }
        return nil
    }
    func shouldPress(for command: String) -> Bool {
        self == (command == "pause" ? .pause : .play)
    }
}

/// Wait briefly for a phrase to settle before resolving shared command prefixes.
struct SpeechUtteranceSettler {
    private var phrase = ""
    private var words: [VoiceWord] = []
    private var changedAt: TimeInterval = 0
    private var pending = false

    mutating func update(phrase: String, words: [VoiceWord], time: TimeInterval) {
        self.words = words
        let normalized = phrase.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if normalized != self.phrase {
            self.phrase = normalized
            changedAt = time
            pending = !normalized.isEmpty
        }
    }

    mutating func takeReady(time: TimeInterval, final: Bool = false) -> [VoiceWord]? {
        guard pending, final || time - changedAt >= 0.55 else { return nil }
        pending = false
        return words
    }
}
