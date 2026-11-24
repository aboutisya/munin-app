@preconcurrency import AVFoundation
import MnemosyneCore
import MnemosynePipeline
import Observation
import SwiftUI

/// Запись голосового отпечатка: 20 секунд чтения абзаца → эмбеддинг → `people.json` (§2, «Голосовой отпечаток»).
@MainActor
@Observable
final class VoiceEnrollment {
    enum State: Equatable {
        case idle, recording, processing, done, failed(String)
    }

    static let seconds: Double = 20
    static let paragraph = String(localized: """
    Сегодня обсуждаем планы на квартал. Сначала коротко пройдёмся по итогам прошлого спринта, \
    потом разберём риски по релизу и договоримся, кто за что отвечает. Если что-то останется \
    непонятным, вернёмся к этому в конце встречи. Предлагаю не затягивать и уложиться в полчаса.
    """)

    private(set) var state: State = .idle
    private(set) var elapsed: Double = 0
    private(set) var level: Float = 0

    @ObservationIgnored private let store: MeetingStore
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var file: AVAudioFile?
    @ObservationIgnored private var url: URL?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var startedAt: Date?

    init(store: MeetingStore) { self.store = store }

    var hasVoice: Bool { PeopleDirectory.load(root: store.root).myVoice != nil }

    func start(name: String) {
        guard state != .recording, state != .processing else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { state = .failed(String(localized: "Микрофон недоступен")); return }
        let url = FileManager.default.temporaryDirectory.appending(path: "mnemosyne-voice-\(UUID().uuidString).caf")
        do {
            let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false)!
            let file = try AVAudioFile(forWriting: url, settings: mono.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            Self.installTap(on: input, format: format, mono: mono, file: file) { [weak self] rms in
                Task { @MainActor in self?.level = min(1, rms * 8) }
            }
            try engine.start()
            self.engine = engine
            self.file = file
            self.url = url
        } catch {
            state = .failed(String(localized: "Не удалось начать запись: \(error.localizedDescription)"))
            return
        }
        state = .recording
        elapsed = 0
        startedAt = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let s = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(s)
                if self.elapsed >= Self.seconds { self.finish(name: name) }
            }
        }
    }

    /// Блок тапа вызывается на аудиопотоке: ставим его вне main actor, иначе Swift 6 проверит изоляцию и уронит процесс.
    nonisolated private static func installTap(on input: AVAudioInputNode, format: AVAudioFormat, mono: AVAudioFormat,
                                               file: AVAudioFile, level: @escaping @Sendable (Float) -> Void) {
        nonisolated(unsafe) let f = file
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            guard let ch = buffer.floatChannelData, buffer.frameLength > 0,
                  let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength) else { return }
            out.frameLength = buffer.frameLength
            out.floatChannelData![0].update(from: ch[0], count: Int(buffer.frameLength))
            try? f.write(from: out)
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += ch[0][i] * ch[0][i] }
            level((sum / Float(buffer.frameLength)).squareRoot())
        }
    }

    func cancel() {
        stopEngine()
        state = .idle
    }

    private func stopEngine() {
        timer?.invalidate()
        timer = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        file = nil
        level = 0
    }

    private func finish(name: String) {
        stopEngine()
        guard let url else { return }
        state = .processing
        let root = store.root
        Task {
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                let voice = try await VoiceEnroller.embedding(of: url)
                var people = PeopleDirectory.load(root: root)
                people.setMyVoice(name: name, voice: voice)
                try people.save(root: root)
                state = .done
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }
}

/// Блок записи голоса: абзац, кнопка, индикатор громкости и прогресс.
struct VoiceEnrollmentView: View {
    let model: VoiceEnrollment
    let name: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Нажмите «Записать» и прочитайте вслух обычным голосом:").font(.system(size: 13)).foregroundStyle(Theme.sec)
            Text(VoiceEnrollment.paragraph)
                .font(.system(size: 15)).lineSpacing(4)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.hover))
            HStack(spacing: 12) {
                switch model.state {
                case .recording:
                    Button("Отмена") { model.cancel() }.buttonStyle(Pill())
                    ProgressView(value: min(1, model.elapsed / VoiceEnrollment.seconds)).frame(width: 160)
                    Capsule().fill(Theme.red).frame(width: max(4, CGFloat(model.level) * 60), height: 6)
                        .animation(.linear(duration: 0.1), value: model.level)
                    Text("\(Int(VoiceEnrollment.seconds - model.elapsed)) с").font(Theme.mono).foregroundStyle(Theme.sec)
                case .processing:
                    ProgressView().controlSize(.small)
                    Text("Считаю отпечаток…").font(.system(size: 13)).foregroundStyle(Theme.sec)
                default:
                    Button(model.hasVoice ? "Записать заново" : "Записать") { model.start(name: name) }.buttonStyle(Pill(dark: true))
                    if case .failed(let e) = model.state {
                        Text(e).font(.system(size: 13)).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true)
                    } else if model.state == .done || model.hasVoice {
                        Label("Голос сохранён", systemImage: "checkmark").font(.system(size: 13)).foregroundStyle(Theme.sec)
                    }
                }
            }
        }
    }
}
