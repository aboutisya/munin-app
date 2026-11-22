import Foundation
import MnemosyneCore

public enum PipelineError: LocalizedError {
    case whisperNotFound
    case whisperFailed(code: Int32, tail: String)
    case noAudio

    public var errorDescription: String? {
        switch self {
        case .whisperNotFound: "Распознавание речи не установлено — откройте Настройки → Распознавание → Установить"
        case .whisperFailed(let code, let tail): "Распознавание завершилось с кодом \(code): \(tail)"
        case .noAudio: "В записи нет аудио"
        }
    }
}

/// Распознавание mlx-whisper отдельным процессом.
/// Основной путь — своё окружение приложения (`WhisperEnvironment`) и `whisper_runner.py`.
/// Запасной — `mlx_whisper` из PATH (так было до раздачи друзьям; нужен ffmpeg).
public struct WhisperRunner: Sendable {
    public static let model = WhisperEnvironment.model

    public let executable: URL
    /// `whisper_runner.py`, если работаем через своё окружение.
    let script: URL?

    public init?() {
        if WhisperEnvironment.isReady, let script = WhisperEnvironment.runnerScript {
            executable = WhisperEnvironment.pythonExecutable
            self.script = script
        } else if let cli = ShellEnvironment.which("mlx_whisper") {
            executable = cli
            script = nil
        } else {
            return nil
        }
    }

    public var usesAppEnvironment: Bool { script != nil }

    /// Распознать WAV. Возвращает путь к JSON. `progress` получает секунды распознанного аудио.
    public func transcribe(wav: URL, outputDir: URL, language: String, prompt: String?,
                           progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        var args: [String]
        if let script {
            args = [script.path, wav.path, "--model", Self.model, "--output-dir", outputDir.path]
        } else {
            args = [
                wav.path,
                "--model", Self.model,
                "--word-timestamps", "True",
                "--condition-on-previous-text", "False",
                "--hallucination-silence-threshold", "2",
                "--output-format", "json",
                "--output-dir", outputDir.path,
                "--verbose", "True",
            ]
        }
        // «Авто»: Whisper сам определяет язык по первым 30 секундам.
        if language != "auto" { args += ["--language", language] }
        if let prompt, !prompt.isEmpty { args += ["--initial-prompt", prompt] }

        let process = Process()
        process.executableURL = executable
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        // Запасной путь: CLI mlx_whisper читает аудио через ffmpeg, а из Finder PATH урезан.
        env["PATH"] = ShellEnvironment.pathString
        // Модель уже в кэше: не ходим в сеть.
        env["HF_HUB_OFFLINE"] = "1"
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONIOENCODING"] = "utf-8"
        process.environment = env

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        let tail = TailBuffer()
        try process.run()
        ChildProcesses.add(process)
        defer { ChildProcesses.remove(process) }

        // Читаем stdout построчно ради прогресса, stderr — ради текста ошибки.
        async let reading: Void = {
            for try await line in out.fileHandleForReading.bytes.lines {
                if let s = WhisperOutput.progressSeconds(fromLine: line) { progress(s) }
            }
        }()
        async let errors: Void = {
            for try await line in err.fileHandleForReading.bytes.lines { tail.append(line) }
        }()
        _ = try? await (reading, errors)

        // Пайпы закрыты — процесс завершается; дожидаемся кода выхода вне главного потока.
        nonisolated(unsafe) let p = process
        await Task.detached { p.waitUntilExit() }.value
        guard process.terminationStatus == 0 else {
            throw PipelineError.whisperFailed(code: process.terminationStatus, tail: tail.text)
        }
        return outputDir.appending(path: wav.deletingPathExtension().lastPathComponent + ".json")
    }
}

/// Последние строки stderr для сообщения об ошибке.
final class TailBuffer: @unchecked Sendable {
    private var lines: [String] = []
    private let lock = NSLock()

    func append(_ line: String) {
        lock.withLock {
            lines.append(line)
            if lines.count > 8 { lines.removeFirst() }
        }
    }

    var text: String { lock.withLock { lines.joined(separator: "\n") } }
}
