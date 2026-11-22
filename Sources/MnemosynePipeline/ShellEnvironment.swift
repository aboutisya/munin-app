import Foundation

/// PATH из login-shell пользователя. Приложение из Finder получает урезанный PATH,
/// а `claude`, поставленный через npm, nvm, bun или Homebrew, лежит в каталогах из `.zshrc`.
public enum ShellEnvironment {
    private static let cache = Cache()

    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var path: [String]?
    }

    /// Каталоги PATH: из login-shell (один раз, с таймаутом), плюс стандартные.
    public static var searchPath: [String] {
        cache.lock.lock(); defer { cache.lock.unlock() }
        if let p = cache.path { return p }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var dirs = loginShellPath() ?? []
        dirs += ["\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin",
                 "\(home)/.npm-global/bin", "\(home)/.bun/bin", "\(home)/.volta/bin", "/usr/bin", "/bin"]
        var seen = Set<String>()
        let result = dirs.filter { !$0.isEmpty && seen.insert($0).inserted }
        cache.path = result
        return result
    }

    public static var pathString: String { searchPath.joined(separator: ":") }

    /// Первый исполняемый файл с таким именем в `searchPath`.
    public static func which(_ name: String) -> URL? {
        for dir in searchPath {
            let p = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: p) { return URL(fileURLWithPath: p) }
        }
        return nil
    }

    /// `$SHELL -ilc 'printf …$PATH…'`. Интерактивный режим нужен: nvm и npm-префиксы обычно в `.zshrc`.
    static func loginShellPath() -> [String]? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-ilc", "printf '__MUNIN__%s__MUNIN__' \"$PATH\""]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(5)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning { p.terminate(); return nil }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard let a = text.range(of: "__MUNIN__"), let b = text.range(of: "__MUNIN__", range: a.upperBound..<text.endIndex) else { return nil }
        return text[a.upperBound..<b.lowerBound].split(separator: ":").map(String.init)
    }
}
