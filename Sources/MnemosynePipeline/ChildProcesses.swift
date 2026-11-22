import Foundation

/// Дочерние процессы приложения (`claude`, Whisper, `uv`). При выходе их нужно остановить:
/// иначе вызов Claude продолжит тратить лимит, а Whisper — греть Mac без хозяина.
public enum ChildProcesses {
    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var items: [ObjectIdentifier: Process] = [:]
    }
    private static let registry = Registry()

    static func add(_ p: Process) {
        registry.lock.withLock { registry.items[ObjectIdentifier(p)] = p }
    }

    static func remove(_ p: Process) {
        _ = registry.lock.withLock { registry.items.removeValue(forKey: ObjectIdentifier(p)) }
    }

    /// Остановить все запущенные дочерние процессы (при выходе из приложения).
    public static func terminateAll() {
        let all = registry.lock.withLock { Array(registry.items.values) }
        for p in all where p.isRunning { p.terminate() }
    }
}
