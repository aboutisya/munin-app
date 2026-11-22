import Foundation
import MnemosyneCore

/// Claude Code CLI в headless-режиме по подписке. Никаких API-ключей:
/// переменные, переключающие CLI на платный API, вычищаются из окружения процесса.
public struct ClaudeCLI: Sendable {
    public enum CLIError: LocalizedError {
        case notInstalled
        case notSubscription(String)
        case apiKeyConfigured(String)
        case failed(code: Int32, text: String)
        case badOutput(String)
        case usageLimit(retryAt: Date?, text: String)

        public var errorDescription: String? {
            switch self {
            case .notInstalled: "Claude Code не найден. Установите CLI и выполните claude /login"
            case .notSubscription(let s): "Claude Code не авторизован по подписке: \(s). Выполните claude /login"
            case .apiKeyConfigured(let s): "В настройках Claude Code задан API-ключ (\(s)). Мунин работает только по подписке"
            case .failed(let code, let text): "claude завершился с кодом \(code): \(text)"
            case .badOutput(let text): "Скилл вернул неожиданный формат: \(text)"
            case .usageLimit: "Лимит подписки исчерпан"
            }
        }
    }

    public struct AuthStatus: Sendable {
        public var loggedIn: Bool
        public var authMethod: String
        public var subscriptionType: String
        public var planTier: String
        public var loginExpiresAt: Date?
    }

    /// Переменные, при которых CLI уходит на платный API или чужой бэкенд.
    static let strippedEnv = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
                              "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"]

    public let executable: URL
    /// Пустая рабочая папка: в неё не попадают CLAUDE.md проектов.
    public let workDir: URL

    public init?(workDir: URL) {
        // Для проверки очереди на поддельном CLI (например, отвечающем 429).
        if let custom = ProcessInfo.processInfo.environment["MNEMOSYNE_CLAUDE_PATH"] {
            guard FileManager.default.isExecutableFile(atPath: custom) else { return nil }
            executable = URL(fileURLWithPath: custom)
        } else {
            // claude ставят по-разному: нативный установщик, npm, nvm, brew — ищем по PATH из login-shell.
            guard let found = ShellEnvironment.which("claude") else { return nil }
            executable = found
        }
        self.workDir = workDir
    }

    // MARK: - Проверка подписки (§5.2)

    public func checkSubscription() async throws -> AuthStatus {
        let out = try await run(["auth", "status"], stdin: nil, timeout: 30)
        guard out.code == 0, let obj = try? JSONSerialization.jsonObject(with: out.stdout) as? [String: Any] else {
            throw CLIError.notSubscription("auth status не ответил")
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let status = AuthStatus(
            loggedIn: obj["loggedIn"] as? Bool ?? false,
            authMethod: obj["authMethod"] as? String ?? "",
            subscriptionType: obj["subscriptionType"] as? String ?? "",
            planTier: obj["planTier"] as? String ?? "",
            loginExpiresAt: (obj["loginExpiresAt"] as? String).flatMap { iso.date(from: $0) })
        guard status.loggedIn else { throw CLIError.notSubscription("не выполнен вход") }
        guard status.authMethod == "claude.ai" else { throw CLIError.notSubscription("метод входа \(status.authMethod)") }
        guard ["max", "pro", "team", "enterprise"].contains(status.subscriptionType) else {
            throw CLIError.notSubscription("подписка \(status.subscriptionType)")
        }
        try Self.checkSettings()
        return status
    }

    /// В `~/.claude/settings.json` не должно быть apiKeyHelper и ключа в env.
    static func checkSettings() throws {
        let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/settings.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if obj["apiKeyHelper"] != nil { throw CLIError.apiKeyConfigured("apiKeyHelper") }
        if let env = obj["env"] as? [String: Any] {
            for key in strippedEnv where env[key] != nil { throw CLIError.apiKeyConfigured("env.\(key)") }
        }
    }

    // MARK: - Вызов скилла

    /// `claude -p "/<skill>" --json-schema … < input`. Возвращает разобранный ответ.
    /// Исчерпанный лимит — `CLIError.usageLimit` с временем повтора, если CLI его назвал.
    public func runSkill(_ skill: String, input: String, schema: String?, model: String, effort: String = "medium",
                         tools: String = "", extraArgs: [String] = [], timeout: TimeInterval = 900,
                         rawOutput: URL? = nil) async throws -> ClaudeResult {
        var args = ["-p", "/\(skill)",
                    "--model", model,
                    "--effort", effort,
                    "--output-format", "json",
                    "--tools", tools,
                    "--strict-mcp-config",
                    "--no-session-persistence",
                    "--setting-sources", "user"]
        if let schema { args += ["--json-schema", schema] }
        args += extraArgs
        let out = try await run(args, stdin: Data(input.utf8), timeout: timeout)
        // Для разбора: что ушло в модель и что вернулось. Только локально, в рабочей папке встречи.
        if let rawOutput {
            try? FileManager.default.createDirectory(at: rawOutput.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(input.utf8).write(to: rawOutput.deletingPathExtension().appendingPathExtension("input.md"))
            try? out.stdout.write(to: rawOutput)
        }
        guard let result = try? ClaudeResult.parse(out.stdout) else {
            let text = String(decoding: out.stdout + out.stderr, as: UTF8.self)
            if ClaudeResult.limitMarkers.contains(where: text.lowercased().contains) {
                throw CLIError.usageLimit(retryAt: LimitRetry.resetTime(in: text, now: Date()), text: String(text.prefix(300)))
            }
            throw CLIError.failed(code: out.code, text: String(text.suffix(400)))
        }
        if result.isUsageLimit {
            let text = result.result ?? ""
            throw CLIError.usageLimit(retryAt: LimitRetry.resetTime(in: text, now: Date()), text: String(text.prefix(300)))
        }
        if result.isError { throw CLIError.failed(code: out.code, text: String((result.result ?? "").prefix(400))) }
        return result
    }

    // MARK: - Процесс

    struct Output { var code: Int32; var stdout: Data; var stderr: Data }

    func run(_ args: [String], stdin: Data?, timeout: TimeInterval) async throws -> Output {
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        process.currentDirectoryURL = workDir
        var env = ProcessInfo.processInfo.environment
        for key in Self.strippedEnv { env.removeValue(forKey: key) }
        // npm-версия claude — скрипт на node: нужен тот же PATH, что в терминале.
        env["PATH"] = ShellEnvironment.pathString
        env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        process.environment = env

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        ChildProcesses.add(process)
        defer { ChildProcesses.remove(process) }

        // Таймаут: долгий вызов убиваем, чтобы очередь не встала навсегда.
        nonisolated(unsafe) let p = process
        let killer = Task.detached {
            try await Task.sleep(for: .seconds(timeout))
            if p.isRunning { p.terminate() }
        }
        if let stdin { try? inPipe.fileHandleForWriting.write(contentsOf: stdin) }
        try? inPipe.fileHandleForWriting.close()

        async let out = Task.detached { outPipe.fileHandleForReading.readDataToEndOfFile() }.value
        async let err = Task.detached { errPipe.fileHandleForReading.readDataToEndOfFile() }.value
        let (stdout, stderr) = await (out, err)
        await Task.detached { p.waitUntilExit() }.value
        killer.cancel()
        return Output(code: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}
