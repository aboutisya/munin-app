import Foundation

public enum RecordingMode: String, Codable, Sendable, CaseIterable {
    case online, offline, hybrid

    public var title: String {
        switch self {
        case .online: "Онлайн"
        case .offline: "Офлайн"
        case .hybrid: "Гибрид"
        }
    }
}

/// Шаги конвейера. На этапе 1 используются только `recording` и `saved`.
public enum MeetingStatus: String, Codable, Sendable {
    case recording, saved, transcribing, diarizing, merging
    /// Транскрипт готов, ждём анализа (этап 4).
    case transcribed
    case analyzing, publicSummary = "public", done, failed

    /// Нужна обработка аудио (в т. ч. прерванная на середине).
    public var needsProcessing: Bool {
        [.saved, .transcribing, .diarizing, .merging].contains(self)
    }
}

/// Один вызов Claude: токены и время.
public struct UsageRecord: Codable, Equatable, Sendable {
    public var step: String
    public var model: String
    public var at: Date
    public var inputTokens: Int
    public var outputTokens: Int
    public var durationMs: Int

    public init(step: String, model: String, at: Date, inputTokens: Int, outputTokens: Int, durationMs: Int) {
        self.step = step
        self.model = model
        self.at = at
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.durationMs = durationMs
    }
}

/// Состояние шага конвейера. Перезапуск шага сбрасывает последующие.
public struct StepState: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case pending, running, done, failed
        /// Ждём сброса лимита подписки Claude.
        case queuedLimit = "queued_limit"
    }
    public var status: Status
    public var error: String?
    public var startedAt: Date?
    public var finishedAt: Date?

    public init(status: Status, error: String? = nil, startedAt: Date? = nil, finishedAt: Date? = nil) {
        self.status = status
        self.error = error
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    public var seconds: Double? {
        guard let startedAt, let finishedAt else { return nil }
        return finishedAt.timeIntervalSince(startedAt)
    }
}

public struct TrackInfo: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable { case me, others }

    public var role: Role
    /// Имя файла внутри папки встречи: `audio_me.caf` во время записи, `audio_me.m4a` после.
    public var file: String
    public var device: String?
    /// Host time первого сэмпла, нс. Нужен для расчёта смещения дорожек.
    public var startHostNanos: UInt64?
    public var durationSeconds: Double?
    /// Тишина, вставленная на месте разрывов (переподключение устройства).
    public var paddedSeconds: Double?
}

public struct DeviceEvent: Codable, Equatable, Sendable {
    /// Секунды от начала записи.
    public var at: Double
    public var text: String

    public init(at: Double, text: String) {
        self.at = at
        self.text = text
    }
}

public struct MeetingMeta: Codable, Equatable, Sendable {
    public var schema = 1
    public var id: UUID
    public var title: String
    public var startedAt: Date
    public var endedAt: Date?
    public var mode: RecordingMode
    public var status: MeetingStatus
    public var tracks: [TrackInfo]
    /// Насколько дорожка собеседников начинается позже моей, секунды (может быть отрицательным).
    public var othersOffsetSeconds: Double?
    public var outputKindAtStart: OutputKind?
    public var voiceProcessing: Bool
    public var deviceEvents: [DeviceEvent]
    public var recovered: Bool?
    public var warnings: [String]?
    /// Привязанное событие календаря (снимок на момент привязки).
    public var event: CalendarEventInfo?
    /// Участники: из календаря, позже — добавленные вручную.
    public var participants: [Person]?
    /// Название меняли руками: перепривязка события его не трогает.
    public var titleEdited: Bool?
    /// Шаги обработки: `transcribe`, `diarize`, `merge`, позже `analyze`, `public`.
    public var steps: [String: StepState]?
    /// Не отправлять в Claude: только транскрипт.
    public var skipAnalysis: Bool?
    /// Хэш входа анализа: совпал — повторный вызов не нужен (§5.3).
    public var analysisHash: String?
    /// Событие и участники на момент анализа: изменились — предлагаем обновить саммари.
    public var analysisContext: String?
    /// Хэш входа вызова 2 (публичное саммари).
    public var publicHash: String?
    /// Отмеченные выполненными задачи из анализа (по тексту задачи).
    public var doneTasks: [String]?
    /// Правки задач из анализа: текст, исполнитель, срок или удаление. Ключ — `TaskList.key` исходного текста.
    public var taskEdits: [String: TaskEdit]?
    /// Когда удалили аудио по сроку хранения.
    public var audioDeletedAt: Date?
    /// Расход по вызовам Claude — для статистики в настройках.
    public var usage: [UsageRecord]?
    /// Теги встречи: id из `TagDirectory`.
    public var tags: [UUID]?
    /// Проект встречи: id из `ProjectDirectory`.
    public var project: UUID?
    /// Версии саммари в других стилях (`summaries/<стиль>.md`).
    public var summaryVersions: [SummaryVersion]?
    /// Какой стиль показывать; `nil` — «Деловой» (обычный разбор).
    public var summaryStyle: String?
    /// Язык распознавания этой встречи (`ru`, `en`, `auto`); `nil` — из настроек.
    public var language: String?

    public init(id: UUID = UUID(), title: String, startedAt: Date, mode: RecordingMode) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.mode = mode
        status = .recording
        tracks = []
        voiceProcessing = false
        deviceEvents = []
    }

    public var durationSeconds: Double? {
        endedAt.map { $0.timeIntervalSince(startedAt) }
    }

    public func track(_ role: TrackInfo.Role) -> TrackInfo? {
        tracks.first { $0.role == role }
    }

    /// Отпечаток события на момент анализа. Перепривязка к другому событию меняет
    /// участников и повестку — тогда предлагаем обновить саммари. Ручные правки
    /// участников и имён спикеров не в счёт: они применяются заменой имён.
    public var analysisContextKey: String { event?.id ?? "-" }

    /// Смещение каждой дорожки относительно начала встречи (самой ранней дорожки), с.
    public var trackOffsets: [TrackInfo.Role: Double] {
        let starts = tracks.compactMap { t in t.startHostNanos.map { (t.role, $0) } }
        guard let zero = starts.map(\.1).min() else { return [:] }
        return Dictionary(uniqueKeysWithValues: starts.map { ($0.0, Double($0.1 - zero) / 1e9) })
    }

    /// Смещение дорожек по host time первых сэмплов.
    public static func offset(me: UInt64?, others: UInt64?) -> Double? {
        guard let me, let others else { return nil }
        return (Double(others) - Double(me)) / 1e9
    }
}
