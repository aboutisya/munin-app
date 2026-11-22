import Foundation

/// `transcript.md` — транскрипт для чтения без приложения.
public enum TranscriptMarkdown {
    public static func render(_ t: Transcript, meta: MeetingMeta, calendar: Calendar = .current) -> String {
        var lines: [String] = ["# \(meta.title)", ""]
        let df = DateFormatter()
        df.locale = Locale(identifier: "ru_RU")
        df.calendar = calendar
        df.timeZone = calendar.timeZone
        df.dateFormat = "d MMMM yyyy, HH:mm"
        var info = [df.string(from: meta.startedAt)]
        if let d = meta.durationSeconds { info.append(Format.duration(d)) }
        info.append(meta.mode.title)
        lines.append(info.joined(separator: " · "))

        let people = (meta.participants ?? []).filter { !$0.isMe }.map(\.displayName)
        if !people.isEmpty { lines.append("Участники: " + people.joined(separator: ", ")) }
        lines.append("")

        for u in t.utterances {
            let name = t.speaker(u.speaker)?.label ?? u.speaker
            lines.append("**[\(timestamp(u.start))] \(name):** \(u.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// `00:12:34`
    public static func timestamp(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}
