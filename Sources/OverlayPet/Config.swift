import Foundation

/// ~/.claude/pet/config.json
struct Config: Codable {
    var activePet: String?
    var nexonApiKey: String?
    var scale: Double = 0.6
    var fps: Double = 8
    /// 마지막 상태 갱신 후 이 시간(초)이 지나면 sleep 애니메이션으로.
    var sleepAfterSeconds: Double = 300
    var bubbleSeconds: Double = 5
    var position: Position?
    /// 상태 → 스프라이트 행. 없으면 AnimationMap.defaults 사용.
    var animations: [String: AnimationSpec]?
    /// 상태 → 이펙트 이름 (~/.claude/pet/effects/<name>/)
    var effects: [String: String] = [:]
    var lastEffectPage: String?
    var canvasVersion: Int?   // 키가 없으면 디코딩이 실패하므로 Optional (nil = 1)

    struct Position: Codable { var x: Double; var y: Double }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: Paths.config),
              let cfg = try? JSONDecoder().decode(Config.self, from: data) else { return Config() }
        return cfg
    }

    func save() throws {
        try Paths.ensureDirectories()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try Paths.atomicWrite(try enc.encode(self), to: Paths.config)
        // API 키가 들어가므로 본인만 읽게.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Paths.config.path)
    }
}

enum APIKey {
    /// 우선순위: $NEXON_API_KEY > ./.env > ~/.claude/pet/.env > config.json
    static func resolve() -> String? {
        if let k = ProcessInfo.processInfo.environment["NEXON_API_KEY"], !k.isEmpty { return k }
        for path in [".env", Paths.root.appendingPathComponent(".env").path] {
            if let k = dotenv(path, "NEXON_API_KEY") { return k }
        }
        return Config.load().nexonApiKey
    }

    static func dotenv(_ path: String, _ key: String) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { continue }
            if t[..<eq].trimmingCharacters(in: .whitespaces) == key {
                let v = t[t.index(after: eq)...].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                return v.isEmpty ? nil : v
            }
        }
        return nil
    }
}

/// 한 상태가 어떤 행을 어떻게 재생할지.
struct AnimationSpec: Codable {
    var row: Int
    /// true면 한 번 재생 후 `then` 상태로 넘어간다.
    var once: Bool = false
    var then: String?
    /// 행 기본 fps 대비 배율
    var speed: Double = 1
}
