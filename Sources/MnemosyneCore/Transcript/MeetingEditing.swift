import Foundation

/// Правки встречи из карточки, без повторного вызова Claude:
/// переназначение спикера, добавление участника, пересборка md-файлов.
public struct MeetingEditing: Sendable {
    public let store: MeetingStore

    public init(store: MeetingStore) {
        self.store = store
    }

    public func transcript(_ folder: URL) -> Transcript? {
        try? MeetingProcessorCodec.decoder.decode(Transcript.self, from: Data(contentsOf: folder.appending(path: "transcript.json")))
    }

    public func analysis(_ folder: URL) -> Analysis? {
        try? Analysis.decoder.decode(Analysis.self, from: Data(contentsOf: folder.appending(path: "analysis.json")))
    }

    /// «Собеседник 2 → Мария Смирнова». Транскрипт и саммари обновляются заменой имён,
    /// голос сохраняется в справочник людей.
    public func renameSpeaker(id: UUID, speaker: String, to name: String, email: String? = nil) throws {
        guard let folder = store.locate(id: id), var t = transcript(folder),
              let i = t.speakers.firstIndex(where: { $0.id == speaker }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        t.speakers[i].label = trimmed
        t.speakers[i].email = email ?? t.speakers[i].email
        t.speakers[i].nameSource = "manual"
        t.speakers[i].suggestedName = nil
        t.speakers[i].suggestedEmail = nil
        try MeetingProcessorCodec.encoder.encode(t).write(to: folder.appending(path: "transcript.json"), options: .atomic)

        var people = PeopleDirectory.load(root: store.root)
        people.remember(name: trimmed, email: t.speakers[i].email, voice: t.speakers[i].embedding)
        try people.save(root: store.root)

        // Человек был на встрече — добавляем в участники, если его там нет.
        try store.update(id: id) { m in
            var list = m.participants ?? []
            if !list.contains(where: { $0.displayName.lowercased() == trimmed.lowercased() || ($0.email != nil && $0.email == email) }) {
                list.append(Person(name: trimmed, email: email, status: .accepted))
                m.participants = list
            }
        }
        try rerender(id: id)
    }

    /// Ручное добавление участника (например, молчал на встрече).
    public func addParticipant(id: UUID, name: String, email: String? = nil) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try store.update(id: id) { m in
            var list = m.participants ?? []
            guard !list.contains(where: { $0.displayName.lowercased() == trimmed.lowercased() }) else { return }
            list.append(Person(name: trimmed, email: email, status: .accepted))
            m.participants = list
        }
        var people = PeopleDirectory.load(root: store.root)
        people.remember(name: trimmed, email: email, voice: nil)
        try people.save(root: store.root)
        try rerender(id: id)
    }

    /// Пересобрать `transcript.md` и `summary_personal.md` из JSON (после переименований).
    public func rerender(id: UUID) throws {
        guard let folder = store.locate(id: id) else { return }
        let meta = try store.read(folder)
        guard let t = transcript(folder) else { return }
        try TranscriptMarkdown.render(t, meta: meta).write(to: folder.appending(path: "transcript.md"), atomically: true, encoding: .utf8)
        if let a = analysis(folder) {
            try PersonalSummary.render(a, meta: meta, transcript: t)
                .write(to: folder.appending(path: "summary_personal.md"), atomically: true, encoding: .utf8)
        }
    }

    /// Поменяли событие или участников после анализа — можно обновить саммари одним вызовом.
    /// Переименование спикеров сюда не относится: имена в саммари меняются заменой.
    public static func analysisIsStale(_ meta: MeetingMeta) -> Bool {
        guard let stored = meta.analysisContext else { return false }
        return stored != meta.analysisContextKey
    }
}
