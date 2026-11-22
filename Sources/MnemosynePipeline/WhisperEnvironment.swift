import Foundation
import MnemosyneCore

/// Своё окружение распознавания в `~/Library/Application Support/Munin/whisper`:
/// Python и mlx-whisper ставит `uv` из `.app`, модель скачивается с Hugging Face.
/// torch не ставим: mlx-whisper нужен он только для конвертации моделей. ffmpeg не нужен:
/// `whisper_runner.py` читает WAV сам.
public enum WhisperEnvironment {
    public static let model = "mlx-community/whisper-large-v3-turbo"
    /// Размер модели на диске, байт: для прогресса загрузки.
    public static let modelBytes: Int64 = 1_614_000_000
    static let python = "3.13"
    /// Версии, проверенные на встречах. Меняются — окружение переустанавливается.
    static let whisperPackage = "mlx-whisper==0.4.3"
    static let dependencies = ["mlx==0.32.4", "numpy==2.5.5", "numba==0.68.1", "scipy==1.18.1", "tiktoken==0.14.0",
                               "huggingface_hub==2.4.0", "tqdm==4.70.1", "more-itertools==11.2.1"]
    static var packagesKey: String { ([python, whisperPackage] + dependencies).joined(separator: " ") }

    public static var baseDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Munin/whisper")
    }
    static var venv: URL { baseDir.appending(path: "venv") }
    public static var pythonExecutable: URL { venv.appending(path: "bin/python") }
    static var marker: URL { baseDir.appending(path: "installed.txt") }

    /// `uv` из `.app` (Contents/MacOS/uv), иначе из PATH — для запуска из `swift build`.
    public static var uv: URL? {
        if let exe = Bundle.main.executableURL?.deletingLastPathComponent().appending(path: "uv"),
           FileManager.default.isExecutableFile(atPath: exe.path) { return exe }
        return ShellEnvironment.which("uv")
    }

    public static var runnerScript: URL? { Bundle.main.url(forResource: "whisper_runner", withExtension: "py") }

    /// Кэш Hugging Face: общий с другими программами, чтобы не качать модель дважды.
    public static var hubCache: URL {
        let env = ProcessInfo.processInfo.environment
        if let hub = env["HF_HUB_CACHE"] { return URL(fileURLWithPath: hub) }
        if let home = env["HF_HOME"] { return URL(fileURLWithPath: home).appending(path: "hub") }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".cache/huggingface/hub")
    }

    public static var isEnvironmentReady: Bool {
        FileManager.default.isExecutableFile(atPath: pythonExecutable.path)
            && (try? String(contentsOf: marker, encoding: .utf8)) == packagesKey
    }

    public static var isModelReady: Bool {
        let snapshots = hubCache.appending(path: "models--\(model.replacingOccurrences(of: "/", with: "--"))/snapshots")
        let dirs = (try? FileManager.default.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil)) ?? []
        return dirs.contains { dir in
            let w = dir.appending(path: "weights.safetensors").resolvingSymlinksInPath()
            let size = (try? FileManager.default.attributesOfItem(atPath: w.path)[.size] as? Int64) ?? 0
            return size > modelBytes / 2
        }
    }

    public static var isReady: Bool { isEnvironmentReady && isModelReady && runnerScript != nil }

    public enum SetupError: LocalizedError {
        case noUV
        case failed(String)
        public var errorDescription: String? {
            switch self {
            case .noUV: "В приложении нет uv — пересоберите или скачайте Мунин заново"
            case .failed(let s): s
            }
        }
    }

    /// Python и пакеты. Идемпотентно: при совпадении версий ничего не делает.
    public static func installEnvironment(log: @escaping @Sendable (String) -> Void) async throws {
        guard !isEnvironmentReady else { return }
        guard let uv else { throw SetupError.noUV }
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: venv)
        let env = uvEnvironment()
        log("Ставлю Python \(python)…")
        try await run(uv, ["venv", "--python", python, "--seed", "--quiet", venv.path], env: env, log: log)
        log("Ставлю mlx-whisper…")
        try await run(uv, ["pip", "install", "--python", pythonExecutable.path, "--quiet", "--no-deps", whisperPackage], env: env, log: log)
        log("Ставлю зависимости…")
        try await run(uv, ["pip", "install", "--python", pythonExecutable.path, "--quiet"] + dependencies, env: env, log: log)
        try packagesKey.write(to: marker, atomically: true, encoding: .utf8)
        // Кэш скачанных пакетов больше не нужен: venv на APFS — отдельные копии файлов.
        try? FileManager.default.removeItem(at: baseDir.appending(path: "uv-cache"))
    }

    /// Модель. `progress` — доля 0…1 по размеру скачанного.
    public static func downloadModel(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard !isModelReady else { progress(1); return }
        let baseline = directorySize(hubCache)
        let poll = Task.detached {
            while !Task.isCancelled {
                let done = Double(directorySize(hubCache) - baseline) / Double(modelBytes)
                progress(min(0.99, max(0, done)))
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
        defer { poll.cancel() }
        var env = ProcessInfo.processInfo.environment
        env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        let code = "from huggingface_hub import snapshot_download; snapshot_download('\(model)')"
        try await run(pythonExecutable, ["-c", code], env: env, log: { _ in })
        guard isModelReady else { throw SetupError.failed("Модель скачалась не полностью — попробуйте ещё раз") }
        progress(1)
    }

    static func uvEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // Всё своё — в папке приложения: Python, кэш пакетов. Чужие настройки uv не влияют.
        env["UV_PYTHON_INSTALL_DIR"] = baseDir.appending(path: "python").path
        env["UV_CACHE_DIR"] = baseDir.appending(path: "uv-cache").path
        env["UV_PYTHON_PREFERENCE"] = "only-managed"
        env["UV_NO_CONFIG"] = "1"
        env.removeValue(forKey: "VIRTUAL_ENV")
        return env
    }

    static func directorySize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
            if v?.isSymbolicLink == true { continue }
            total += Int64(v?.fileSize ?? 0)
        }
        return total
    }

    static func run(_ exe: URL, _ args: [String], env: [String: String], log: @escaping @Sendable (String) -> Void) async throws {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.environment = env
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        let tail = TailBuffer()
        try p.run()
        ChildProcesses.add(p)
        defer { ChildProcesses.remove(p) }
        for try await line in err.fileHandleForReading.bytes.lines { tail.append(line); log(line) }
        nonisolated(unsafe) let proc = p
        await Task.detached { proc.waitUntilExit() }.value
        guard p.terminationStatus == 0 else {
            throw SetupError.failed("\(exe.lastPathComponent) \(args.first ?? ""): код \(p.terminationStatus)\n\(tail.text)")
        }
    }
}
