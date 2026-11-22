import Foundation
import MnemosyneCore
import MnemosynePipeline
import Observation
import SwiftUI

/// Установка распознавания: Python и mlx-whisper через `uv`, затем модель. Одна на приложение —
/// онбординг и настройки показывают один и тот же прогресс.
@MainActor
@Observable
final class WhisperSetup {
    enum State: Equatable {
        case notInstalled
        case installing(String)
        case downloading(Double)
        case ready
        case failed(String)
    }

    private(set) var state: State

    init() {
        state = WhisperEnvironment.isReady ? .ready : .notInstalled
    }

    var isBusy: Bool {
        switch state {
        case .installing, .downloading: true
        default: false
        }
    }

    func refresh() {
        if !isBusy { state = WhisperEnvironment.isReady ? .ready : (state == .ready ? .notInstalled : state) }
    }

    func install() {
        guard !isBusy else { return }
        state = .installing("Готовлю окружение…")
        Task {
            do {
                try await WhisperEnvironment.installEnvironment { line in
                    let text = Self.humanize(line)
                    guard let text else { return }
                    Task { @MainActor in if case .installing = self.state { self.state = .installing(text) } }
                }
                state = .downloading(0)
                try await WhisperEnvironment.downloadModel { p in
                    Task { @MainActor in if case .downloading = self.state { self.state = .downloading(p) } }
                }
                state = WhisperEnvironment.isReady ? .ready : .failed("Установка не завершилась — попробуйте ещё раз")
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Строки из лога `installEnvironment`, которые стоит показать человеку.
    nonisolated static func humanize(_ line: String) -> String? {
        line.hasPrefix("Ставлю") || line.hasPrefix("Готовлю") ? line : nil
    }
}

/// Строка «Распознавание речи» с кнопкой и прогрессом — для онбординга и настроек.
struct WhisperSetupRow: View {
    let setup: WhisperSetup
    var compact = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if !compact {
                Image(systemName: "waveform").font(.system(size: 15)).foregroundStyle(Theme.sec).frame(width: 22)
            }
            VStack(alignment: .leading, spacing: 4) {
                if !compact { Text("Распознавание речи").font(.system(size: 15, weight: .semibold)) }
                switch setup.state {
                case .notInstalled:
                    Text("Работает на этом Mac. Скачаю около 2 ГБ: Python, mlx-whisper и модель Whisper. Один раз.")
                        .font(.system(size: 13)).foregroundStyle(Theme.sec).fixedSize(horizontal: false, vertical: true)
                case .installing(let text):
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(text).font(.system(size: 13)).foregroundStyle(Theme.sec)
                    }
                case .downloading(let p):
                    ProgressView(value: p).frame(maxWidth: 280)
                    Text("Скачиваю модель: \(Int(p * 100))% из 1,6 ГБ").font(.system(size: 13)).foregroundStyle(Theme.sec)
                case .ready:
                    Text("Установлено. Модель large-v3-turbo, всё работает локально.").font(.system(size: 13)).foregroundStyle(Theme.sec)
                case .failed(let e):
                    Text(e).font(.system(size: 13)).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true).lineLimit(6)
                }
            }
            Spacer(minLength: 12)
            switch setup.state {
            case .ready: Label("Готово", systemImage: "checkmark").font(.system(size: 13)).foregroundStyle(Theme.sec)
            case .notInstalled: Button("Установить") { setup.install() }.buttonStyle(Pill(dark: true))
            case .failed: Button("Повторить") { setup.install() }.buttonStyle(Pill())
            default: EmptyView()
            }
        }
    }
}
