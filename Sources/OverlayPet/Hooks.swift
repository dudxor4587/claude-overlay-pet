import Foundation

/// ~/.claude/settings.json 의 hooks 에 우리 훅을 넣고 뺀다.
/// 훅 커맨드는 `"<binary>" hook <state> #overlay-pet` 형태이며, 마커 주석으로 우리 것만 골라 제거한다.
enum Hooks {
    static let marker = "#overlay-pet"

    /// (이벤트, matcher, 상태)
    static let table: [(event: String, matcher: String?, state: String)] = [
        ("SessionStart", nil, "start"),
        ("UserPromptSubmit", nil, "prompt"),
        ("PreToolUse", "Bash", "bash"),
        ("PreToolUse", "Edit|Write|MultiEdit|NotebookEdit", "edit"),
        ("Notification", nil, "notify"),
        ("PostToolUseFailure", nil, "error"),
        ("Stop", nil, "done"),
        ("SessionEnd", nil, "end"),
    ]

    static var binaryPath: String {
        URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
    }

    static func command(_ state: String) -> String {
        "\"\(binaryPath)\" hook \(state) \(marker)"
    }

    private static func loadSettings() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: Paths.claudeSettings) else { return [:] }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PetError("settings.json 이 JSON 객체가 아닙니다")
        }
        return obj
    }

    private static func saveSettings(_ obj: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(at: Paths.claudeSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Paths.atomicWrite(data, to: Paths.claudeSettings)
    }

    private static func isOurs(_ hook: [String: Any]) -> Bool {
        (hook["command"] as? String)?.contains(marker) == true
    }

    /// 우리 훅만 제거한 hooks 딕셔너리
    private static func stripped(_ hooks: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { out[event] = value; continue }
            let kept = groups.compactMap { g -> [String: Any]? in
                var g = g
                let inner = (g["hooks"] as? [[String: Any]] ?? []).filter { !isOurs($0) }
                if inner.isEmpty { return nil }
                g["hooks"] = inner
                return g
            }
            if !kept.isEmpty { out[event] = kept }
        }
        return out
    }

    static func install() throws {
        var settings = try loadSettings()
        var hooks = stripped(settings["hooks"] as? [String: Any] ?? [:])
        for row in table {
            var groups = hooks[row.event] as? [[String: Any]] ?? []
            var g: [String: Any] = ["hooks": [["type": "command", "command": command(row.state), "async": true]]]
            if let m = row.matcher { g["matcher"] = m }
            groups.append(g)
            hooks[row.event] = groups
        }
        settings["hooks"] = hooks
        try saveSettings(settings)
    }

    static func uninstall() throws {
        var settings = try loadSettings()
        settings["hooks"] = stripped(settings["hooks"] as? [String: Any] ?? [:])
        try saveSettings(settings)
    }

    static func isInstalled() -> Bool {
        guard let hooks = (try? loadSettings())?["hooks"] as? [String: Any] else { return false }
        for (_, v) in hooks {
            for g in v as? [[String: Any]] ?? [] {
                for h in g["hooks"] as? [[String: Any]] ?? [] where isOurs(h) && (h["command"] as? String)?.contains(binaryPath) == true { return true }
            }
        }
        return false
    }

    /// `hook <state>` 서브커맨드: stdin 의 훅 JSON 을 읽어 state.json 에 쓴다.
    static func handleEvent(state: String) {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let json = (try? JSONSerialization.jsonObject(with: input) as? [String: Any]) ?? [:]
        var message = json["message"] as? String
        if state == "error", let tool = json["tool_name"] as? String { message = "\(tool) 실패" }
        let cwd = (json["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
        let sid = json["session_id"] as? String
        let file = PetStateFile(
            state: state,
            tool: json["tool_name"] as? String,
            message: message,
            cwd: cwd,
            name: sid.flatMap(sessionName),
            sessionId: sid,
            ts: Date().timeIntervalSince1970)
        try? file.write()
    }

    /// ~/.claude/sessions/<pid>.json 에서 세션 이름을 찾는다. 자동 생성 이름(nameSource=derived)은 무시.
    static func sessionName(_ sessionId: String) -> String? {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        for f in files where f.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(f)),
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  j["sessionId"] as? String == sessionId else { continue }
            if (j["nameSource"] as? String) == "derived" { return nil }
            if let n = j["name"] as? String, !n.trimmingCharacters(in: .whitespaces).isEmpty { return n }
            return nil
        }
        return nil
    }
}
