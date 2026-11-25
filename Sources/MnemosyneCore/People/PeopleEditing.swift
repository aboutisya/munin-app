import Foundation

/// Правки из раздела «Люди»: назвать голос, переименовать человека везде, сбросить голос, слепок.
extension MeetingEditing {
    /// Назвать неизвестный голос на всех встречах, где он звучит. Голос запоминается в справочнике.
    @discardableResult
    public func nameVoice(_ refs: [PeopleOverview.VoiceRef], name: String, email: String? = nil) throws -> PeopleDirectory.Record? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for r in refs { try renameSpeaker(id: r.meetingId, speaker: r.speakerId, to: trimmed, email: email) }
        return PeopleDirectory.load(root: store.root).find(name: trimmed, email: email)
    }

    /// Новое имя человека — в справочнике и во всех транскриптах, где он назван.
    public func renamePerson(_ id: UUID, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var people = PeopleDirectory.load(root: store.root)
        guard !trimmed.isEmpty, let old = people.person(id)?.name, old != trimmed else { return }
        people.update(id) { $0.name = trimmed }
        try people.save(root: store.root)
        let key = old.lowercased()
        for item in store.list() {
            guard var t = transcript(item.folder) else { continue }
            var changed = false
            for i in t.speakers.indices where t.speakers[i].nameSource != "generic" && t.speakers[i].id != "me"
                && t.speakers[i].label.lowercased() == key {
                t.speakers[i].label = trimmed
                changed = true
            }
            var meta = item.meta
            if var list = meta.participants, let i = list.firstIndex(where: { $0.name.lowercased() == key }) {
                list[i].name = trimmed
                _ = try? store.update(id: meta.id) { $0.participants = list }
                meta.participants = list
                changed = true
            }
            guard changed else { continue }
            try MeetingProcessorCodec.encoder.encode(t).write(to: item.folder.appending(path: "transcript.json"), options: .atomic)
            try rerender(id: meta.id)
        }
    }

    /// Голос записан не тот: забыть отпечатки и слепок. Имена в прошлых встречах остаются.
    public func clearVoice(_ id: UUID) throws {
        var people = PeopleDirectory.load(root: store.root)
        if let file = people.person(id)?.sample {
            try? FileManager.default.removeItem(at: PeopleDirectory.sampleURL(root: store.root, file: file))
        }
        people.update(id) {
            $0.voices = []
            $0.sample = nil
            $0.sampleSource = nil
        }
        try people.save(root: store.root)
    }

    /// Вырезать слепок голоса человека со встречи и запомнить его в справочнике.
    public func makeSample(person id: UUID, meeting: UUID, speaker: String, source: String) async throws {
        guard let folder = store.locate(id: meeting), let t = transcript(folder) else { return }
        let meta = try store.read(folder)
        let file = "\(id.uuidString).m4a"
        let tmp = PeopleDirectory.samplesDirectory(root: store.root).appending(path: "\(id.uuidString).new.m4a")
        try await VoiceSamples.export(folder: folder, meta: meta, transcript: t, speaker: speaker, to: tmp)
        let target = PeopleDirectory.sampleURL(root: store.root, file: file)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: tmp, to: target)
        var people = PeopleDirectory.load(root: store.root)
        people.update(id) {
            $0.sample = file
            $0.sampleSource = source
        }
        try people.save(root: store.root)
    }

    /// Слепок неназванного голоса — во временной папке, его можно пересоздать, пока аудио встречи на месте.
    public func unknownSample(_ ref: PeopleOverview.VoiceRef) async throws -> URL {
        let url = PeopleDirectory.samplesDirectory(root: store.root)
            .appending(path: "unknown/\(ref.meetingId.uuidString)-\(ref.speakerId.replacingOccurrences(of: ":", with: "_")).m4a")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard let folder = store.locate(id: ref.meetingId), let t = transcript(folder) else { throw VoiceSamples.SampleError.noAudio }
        try await VoiceSamples.export(folder: folder, meta: try store.read(folder), transcript: t, speaker: ref.speakerId, to: url)
        return url
    }
}
