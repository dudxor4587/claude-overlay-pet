import Foundation

/// 모든 사용자 데이터는 ~/.claude/pet 아래에 둔다. 레포에는 에셋을 절대 넣지 않는다.
enum Paths {
    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/pet", isDirectory: true)
    static let config = root.appendingPathComponent("config.json")
    static let state = root.appendingPathComponent("state.json")
    static let pets = root.appendingPathComponent("pets", isDirectory: true)
    static let effects = root.appendingPathComponent("effects", isDirectory: true)
    static let claudeSettings = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/settings.json")

    static func ensureDirectories() throws {
        for dir in [root, pets, effects] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    static func petDirectory(_ id: String) -> URL { pets.appendingPathComponent(id, isDirectory: true) }
    static func effectDirectory(_ name: String) -> URL { effects.appendingPathComponent(name, isDirectory: true) }

    /// 같은 파일을 감시하는 앱이 절반만 읽는 일이 없도록 임시 파일 + rename 으로 쓴다.
    static func atomicWrite(_ data: Data, to url: URL) throws {
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier).tmp")
        try data.write(to: tmp)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}
