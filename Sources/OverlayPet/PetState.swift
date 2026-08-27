import Foundation

/// ~/.claude/pet/state.json — 훅이 쓰고 앱이 읽는다.
struct PetStateFile: Codable {
    var state: String
    var tool: String?
    var message: String?
    var cwd: String?
    /// 사용자가 /rename 으로 지은 세션 이름 (없으면 nil → 폴더명 표시)
    var name: String?
    var sessionId: String?
    var ts: Double

    enum CodingKeys: String, CodingKey {
        case state, tool, message, cwd, name, ts
        case sessionId = "session_id"
    }

    /// 말풍선에 보일 세션 표시명
    var label: String { name ?? cwd ?? "?" }

    static func read() -> PetStateFile? {
        guard let data = try? Data(contentsOf: Paths.state) else { return nil }
        return try? JSONDecoder().decode(PetStateFile.self, from: data)
    }

    func write() throws {
        try Paths.ensureDirectories()
        try Paths.atomicWrite(try JSONEncoder().encode(self), to: Paths.state)
    }
}

/// 스프라이트 시트 행 의미 (maple-hatch-pet 호환 레이아웃, 8열 9행).
enum SheetRow {
    static let idle = 0        // 서기
    static let walk = 1        // 걷기 (오른쪽)
    static let walkLeft = 2    // 걷기 (왼쪽) / 빠른 걷기
    static let wave = 3        // 짧은 동작
    static let celebrate = 4   // 점프·축하
    static let ghost = 5       // 유령 (실패)
    static let think = 6       // 대기·생각
    static let attack = 7      // 실행 중
    static let lie = 8         // 눕기
}

enum AnimationMap {
    /// 훅 상태 → 애니메이션. config.json 의 "animations" 로 덮어쓸 수 있다.
    static let defaults: [String: AnimationSpec] = [
        "idle":   AnimationSpec(row: SheetRow.idle),
        "start":  AnimationSpec(row: SheetRow.celebrate, once: true, then: "idle"),
        "prompt": AnimationSpec(row: SheetRow.think),
        "bash":   AnimationSpec(row: SheetRow.attack),
        "edit":   AnimationSpec(row: SheetRow.walk, speed: 1.5),
        "notify": AnimationSpec(row: SheetRow.wave),
        "error":  AnimationSpec(row: SheetRow.ghost),
        "done":   AnimationSpec(row: SheetRow.celebrate, once: true, then: "idle"),
        "end":    AnimationSpec(row: SheetRow.lie),
        "sleep":  AnimationSpec(row: SheetRow.lie, speed: 0.4),
    ]

    static func resolve(_ config: Config) -> [String: AnimationSpec] {
        defaults.merging(config.animations ?? [:]) { _, user in user }
    }

    static let bubbleText: [String: String] = [
        "start": "안녕! 세션 시작",
        "prompt": "생각 중…",
        "bash": "명령 실행 중",
        "edit": "파일 수정 중",
        "notify": "확인해 줘!",
        "error": "앗, 실패했어",
        "done": "끝났어!",
        "end": "세션 종료",
    ]
}
