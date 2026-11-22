import Foundation

/// Скиллы приложения лежат внутри `.app` и ставятся в `~/.claude/skills` при запуске:
/// у друзей их ещё нет, а после обновления приложения нужна новая версия.
/// Чужие правки не теряются: перед заменой старый `SKILL.md` сохраняется рядом с версией в имени.
public enum SkillInstaller {
    public struct Result: Sendable, Equatable {
        public var installed: [String] = []
        public var upToDate: [String] = []
    }

    public static var userSkillsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/skills")
    }

    @discardableResult
    public static func install(from bundled: URL, to skillsDir: URL = userSkillsDir) throws -> Result {
        let fm = FileManager.default
        var result = Result()
        let names = (try? fm.contentsOfDirectory(atPath: bundled.path))?.sorted() ?? []
        for name in names {
            let src = bundled.appending(path: name)
            let srcSkill = src.appending(path: "SKILL.md")
            guard let newText = try? String(contentsOf: srcSkill, encoding: .utf8) else { continue }
            let dst = skillsDir.appending(path: name)
            let dstSkill = dst.appending(path: "SKILL.md")
            let newVersion = AnalysisInput.skillVersion(skillFile: newText)
            if let oldText = try? String(contentsOf: dstSkill, encoding: .utf8) {
                let oldVersion = AnalysisInput.skillVersion(skillFile: oldText)
                guard isNewer(newVersion, than: oldVersion) else { result.upToDate.append(name); continue }
                if oldText != newText {
                    try? fm.copyItem(at: dstSkill, to: dst.appending(path: "SKILL.md.\(oldVersion).bak"))
                }
            }
            try fm.createDirectory(at: dst, withIntermediateDirectories: true)
            for file in (try? fm.contentsOfDirectory(atPath: src.path)) ?? [] {
                let to = dst.appending(path: file)
                try? fm.removeItem(at: to)
                try fm.copyItem(at: src.appending(path: file), to: to)
            }
            result.installed.append(name)
        }
        return result
    }

    /// `1.10.0` новее `1.9.3`.
    public static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Есть ли у пользователя скилл (например, необязательный `ru-text`).
    public static func isInstalled(_ name: String, in skillsDir: URL = userSkillsDir) -> Bool {
        FileManager.default.fileExists(atPath: skillsDir.appending(path: "\(name)/SKILL.md").path)
    }
}
