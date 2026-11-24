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
        // Читаем через readabilityHandler (очередь GCD), а не `bytes.lines`: AsyncBytes делает
        // блокирующий read на общем пуле Swift Concurrency, и чтение stdout могло не запуститься —
        // буфер пайпа (64 КБ) заполнялся, Whisper вставал на записи, прогресс висел на 0%.
        let stdoutLines = LineSplitter { line in
            if let s = WhisperOutput.progressSeconds(fromLine: line) { progress(s) }
        }
        let stderrLines = LineSplitter { tail.append($0) }
        out.fileHandleForReading.readabilityHandler = { h in stdoutLines.feed(h.availableData) }
        err.fileHandleForReading.readabilityHandler = { h in stderrLines.feed(h.availableData) }

        let exited = ExitSignal()
        process.terminationHandler = { _ in exited.fire() }
        try process.run()
        ChildProcesses.add(process)
        defer { ChildProcesses.remove(process) }
        await exited.wait()
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        // Хвост, который пришёл между последним вызовом обработчика и выходом процесса.
        stdoutLines.feed((try? out.fileHandleForReading.readToEnd()) ?? Data())
        stderrLines.feed((try? err.fileHandleForReading.readToEnd()) ?? Data())
        stdoutLines.flush()
        stderrLines.flush()
        guard process.terminationStatus == 0 else {
            throw PipelineError.whisperFailed(code: process.terminationStatus, tail: tail.text)
        }
        return outputDir.appending(path: wav.deletingPathExtension().lastPathComponent + ".json")
    }
}

/// Сигнал о выходе процесса: `fire` может прийти раньше, чем начали ждать.
final class ExitSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var waiter: CheckedContinuation<Void, Never>?

    func fire() {
        let w: CheckedContinuation<Void, Never>? = lock.withLock {
            fired = true
            defer { waiter = nil }
            return waiter
        }
        w?.resume()
    }

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let now: Bool = lock.withLock {
                if fired { return true }
                waiter = c
                return false
            }
            if now { c.resume() }
        }
    }
}

/// Режет поток байтов на строки и отдаёт их по одной. Вызывается с очереди пайпа.
final class LineSplitter: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()
    private let onLine: (String) -> Void

    init(_ onLine: @escaping (String) -> Void) { self.onLine = onLine }

    func feed(_ data: Data) {
        guard !data.isEmpty else { return }
        let lines: [String] = lock.withLock {
            buffer.append(data)
            var result: [String] = []
            while let nl = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                if !line.isEmpty { result.append(String(decoding: line, as: UTF8.self)) }
            }
            return result
        }
        lines.forEach(onLine)
    }

    func flush() {
        let rest: Data = lock.withLock { defer { buffer.removeAll() }; return buffer }
        if !rest.isEmpty { onLine(String(decoding: rest, as: UTF8.self)) }
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
