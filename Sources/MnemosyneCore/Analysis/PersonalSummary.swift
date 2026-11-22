import Foundation

/// `summary_personal.md` из `analysis.json` — без отдельного вызова Claude.
public enum PersonalSummary {
    /// `forCopy` — для буфера обмена: то, что видно на вкладке «Саммари», без таймкодов,
    /// диаграмм, тональности и разбора конфликта.
    public static func render(_ a: Analysis, meta: MeetingMeta, transcript t: Transcript, calendar: Calendar = .current,
                              forCopy: Bool = false) -> String {
        let names = speakerNames(a, transcript: t)
        func name(_ code: String) -> String { names[code] ?? code }
        func ts(_ s: String) -> String { forCopy || s.isEmpty ? "" : " `\(s)`" }

        let df = DateFormatter()
        df.locale = Locale(identifier: "ru_RU")
        df.calendar = calendar
        df.timeZone = calendar.timeZone
        df.dateFormat = "d MMMM yyyy, HH:mm"

        var out: [String] = ["# \(meta.title)", ""]
        var info = [df.string(from: meta.startedAt)]
        if let d = meta.durationSeconds { info.append(Format.duration(d)) }
        info.append(meta.mode.title)
        out += [info.joined(separator: " · "), ""]

        if !a.tldr.isEmpty {
            out.append("## Коротко")
            out += a.tldr.map { "- \($0)" }
            out.append("")
        }
        if !a.decisions.isEmpty {
            out.append("## Решения")
            out += a.decisions.map { d in
                "- \(d.text)" + (d.owner.isEmpty ? "" : " — \(name(d.owner))") + ts(d.ts)
            }
            out.append("")
        }
        if !a.actionItems.isEmpty {
            out.append("## Задачи")
            out += a.actionItems.map { i in
                let who = i.who.trimmingCharacters(in: .whitespaces)
                var s = who.isEmpty ? "- [ ] \(i.what) — исполнитель не назван" : "- [ ] **\(name(who))**: \(i.what)"
                if !i.due.isEmpty { s += " — до \(formatDue(i.due, calendar: calendar))" }
                if !i.dueSaid.isEmpty { s += " (\(i.dueSaid))" }
                return s + ts(i.ts)
            }
            out.append("")
        }
        if !a.summaryByTopics.isEmpty {
            out.append("## По темам")
            for topic in a.summaryByTopics {
                out += ["", "### \(topic.topic)\(ts(topic.start))", "", topic.markdown]
            }
            out.append("")
        }
        if !a.insights.isEmpty {
            out.append("## Инсайты")
            out += a.insights.map { "- \($0.text)\(ts($0.ts))" }
            out.append("")
        }
        if !forCopy, !a.diagrams.isEmpty {
            out.append("## Диаграммы")
            for d in a.diagrams {
                out += ["", "### \(d.title)", "", "```mermaid", d.mermaid, "```"]
            }
            out.append("")
        }

        if !forCopy {
        out.append("## Тональность")
        let s = a.sentiment.overall
        out.append("**\(s.label.capitalizedFirst)** (\(String(format: "%+.1f", s.score)))")
        out += s.evidence.map { "> «\($0.quote)» `\($0.ts)`" }
        for p in a.sentiment.perParticipant {
            out.append("")
            out.append("- **\(name(p.speaker))**: \(p.label)")
            out += p.evidence.map { "  > «\($0.quote)» `\($0.ts)`" }
        }
        out.append("")

        if a.conflict.detected {
            out.append("## Конфликт")
            if !a.conflict.kinds.isEmpty { out.append("Тип: " + a.conflict.kinds.joined(separator: ", ")) }
            out += ["", a.conflict.summary, ""]
            if !a.conflict.mySpeechFeedback.isEmpty {
                out.append("### Фидбек по моей речи")
                for f in a.conflict.mySpeechFeedback {
                    out += ["", "> «\(f.quote)» `\(f.ts)`", "", "- Что не так: \(f.problem)", "- Лучше: «\(f.better)»",
                            "- Принцип: \(principleTitle(f.principle))"]
                }
                out.append("")
            }
        }
        }

        out.append("## Участники")
        for p in a.participants.people {
            let n = p.name.isEmpty ? name(p.speaker) : p.name
            out.append("- \(n)" + (p.speaker.isEmpty ? "" : " (\(p.speaker))"))
        }
        if !a.participants.mentionedNotPresent.isEmpty {
            out.append("- Упоминали, но не говорили: " + a.participants.mentionedNotPresent.joined(separator: ", "))
        }
        out.append("")
        return out.joined(separator: "\n")
    }

    /// Код спикера → имя: из ответа модели, иначе подпись из транскрипта.
    public static func speakerNames(_ a: Analysis, transcript t: Transcript) -> [String: String] {
        var result: [String: String] = [:]
        let codes = AnalysisInput.codes(for: t)
        for s in t.speakers { if let c = codes[s.id] { result[c] = s.label } }
        for p in a.participants.people where !p.name.isEmpty && p.confidence >= 0.6 { result[p.speaker] = p.name }
        // Имя, заданное руками или из календаря, важнее догадки модели.
        for s in t.speakers where ["manual", "calendar-1on1", "voice"].contains(s.nameSource) {
            if let c = codes[s.id] { result[c] = s.label }
        }
        result["Я"] = "Я"
        return result
    }

    static func formatDue(_ iso: String, calendar: Calendar) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: iso) else { return iso }
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMMM, EEEEEE"
        return f.string(from: d).lowercased()
    }

    public static func principleTitle(_ code: String) -> String {
        [
            "people_vs_problem": "отделять людей от проблемы",
            "interests_not_positions": "интересы, а не позиции",
            "mutual_gain": "взаимная выгода",
            "objective_criteria": "объективные критерии",
            "batna": "BATNA",
            "nvc": "ненасильственное общение",
            "sbi": "SBI",
            "active_listening": "активное слушание",
            "ethos_pathos_logos": "этос, пафос, логос",
            "framing": "фрейминг",
            "de_escalation": "деэскалация",
            "clarity": "ясность",
        ][code] ?? code
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
