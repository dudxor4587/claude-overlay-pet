import Foundation

/// 넥슨 `character_class`(한국어) → mapleeditors.com 직업 페이지.
/// 모험가는 계열 페이지 하나에 여러 전직 경로가 들어 있어 `path`(4차 직업 영문명)로 걸러낸다.
/// 마법사 페이지는 "Arch Mage" 경로가 둘(불독 → 0, 썬콜 → 1)이라 `pathIndex` 로 구분.
enum JobPages {
    static let base = "https://mapleeditors.com/"

    struct Entry {
        var slugs: [String]
        var path: String? = nil
        var pathIndex: Int = 0
            var pages: [URL] { slugs.map { URL(string: base + $0 + "/")! } }
    }

    static let table: [String: Entry] = [
        // 모험가
        "히어로": Entry(slugs: ["warrior"], path: "Hero"),
        "팔라딘": Entry(slugs: ["warrior"], path: "Paladin"),
        "다크나이트": Entry(slugs: ["warrior"], path: "Dark Knight"),
        "아크메이지(불,독)": Entry(slugs: ["magician"], path: "Arch Mage", pathIndex: 0),
        "아크메이지(썬,콜)": Entry(slugs: ["magician"], path: "Arch Mage", pathIndex: 1),
        "비숍": Entry(slugs: ["magician"], path: "Bishop"),
        "보우마스터": Entry(slugs: ["archer"], path: "Bowmaster"),
        "신궁": Entry(slugs: ["archer"], path: "Marksman"),
        "패스파인더": Entry(slugs: ["pathfinder"]),
        "나이트로드": Entry(slugs: ["thief"], path: "Night Lord"),
        "섀도어": Entry(slugs: ["thief"], path: "Shadower"),
        "듀얼블레이더": Entry(slugs: ["dual-blade"]),
        "바이퍼": Entry(slugs: ["pirate"], path: "Buccaneer"),
        "캡틴": Entry(slugs: ["pirate"], path: "Corsair"),
        "캐논마스터": Entry(slugs: ["cannoneer"]),
        "초보자": Entry(slugs: ["explorer"]),
        // 시그너스
        "소울마스터": Entry(slugs: ["dawn-warrior"]), "플레임위자드": Entry(slugs: ["blaze-wizard"]),
        "윈드브레이커": Entry(slugs: ["wind-archer"]), "나이트워커": Entry(slugs: ["night-walker"]),
        "스트라이커": Entry(slugs: ["thunder-breaker"]), "미하일": Entry(slugs: ["mihile"]),
        "노블레스": Entry(slugs: ["noblesse"]),
        // 영웅
        "아란": Entry(slugs: ["aran"]), "에반": Entry(slugs: ["evan"]),
        "메르세데스": Entry(slugs: ["mercedes"]), "팬텀": Entry(slugs: ["phantom"]),
        "루미너스": Entry(slugs: ["luminous"]), "은월": Entry(slugs: ["shade"]),
        // 레지스탕스
        "배틀메이지": Entry(slugs: ["battle-mage"]), "와일드헌터": Entry(slugs: ["wild-hunter"]),
        "메카닉": Entry(slugs: ["mechanic"]), "데몬슬레이어": Entry(slugs: ["demon-slayer"]),
        "데몬어벤져": Entry(slugs: ["demon-avenger"]), "제논": Entry(slugs: ["xenon"]),
        "블래스터": Entry(slugs: ["blaster"]), "시티즌": Entry(slugs: ["citizen"]), "데몬": Entry(slugs: ["demon"]),
        // 노바
        "카이저": Entry(slugs: ["kaiser"]), "카인": Entry(slugs: ["kain"]),
        "카데나": Entry(slugs: ["cadena"]), "엔젤릭버스터": Entry(slugs: ["angelic-buster"]),
        // 레프
        "일리움": Entry(slugs: ["illium"]), "아크": Entry(slugs: ["ark"]),
        "아델": Entry(slugs: ["adele"]), "칼리": Entry(slugs: ["khali"]),
        // 아니마
        "호영": Entry(slugs: ["hoyoung"]), "라라": Entry(slugs: ["lara"]),
        // 기타
        "제로": Entry(slugs: ["zero"]), "키네시스": Entry(slugs: ["kinesis"]),
        "하야토": Entry(slugs: ["hayato"]), "칸나": Entry(slugs: ["kanna"]), "젯트": Entry(slugs: ["jett"]), "제트": Entry(slugs: ["jett"]),
        "비스트테이머": Entry(slugs: ["beast-tamer"]), "모쿠아": Entry(slugs: ["mo-xuan"]), "젠": Entry(slugs: ["zen"]),
    ]

    /// 1~3차 직업명 → 4차 직업명 (넥슨 character_class 는 현재 차수 이름으로 온다)
    static let aliases: [String: String] = [
        "검사": "히어로", "파이터": "히어로", "크루세이더": "히어로",
        "페이지": "팔라딘", "나이트": "팔라딘",
        "스피어맨": "다크나이트", "버서커": "다크나이트",
        "위자드(불,독)": "아크메이지(불,독)", "메이지(불,독)": "아크메이지(불,독)",
        "위자드(썬,콜)": "아크메이지(썬,콜)", "메이지(썬,콜)": "아크메이지(썬,콜)",
        "클레릭": "비숍", "프리스트": "비숍",
        "헌터": "보우마스터", "레인저": "보우마스터",
        "사수": "신궁", "저격수": "신궁",
        "에인션트아처": "패스파인더",
        "어쌔신": "나이트로드", "허밋": "나이트로드",
        "시프": "섀도어", "시프마스터": "섀도어",
        "세미듀어러": "듀얼블레이더", "듀어러": "듀얼블레이더", "듀얼마스터": "듀얼블레이더", "슬래셔": "듀얼블레이더",
        "듀얼블레이드": "듀얼블레이더",   // 옛 이름·계열명
        "인파이터": "바이퍼", "버커니어": "바이퍼",
        "건슬링거": "캡틴", "발키리": "캡틴",
        "캐논슈터": "캐논마스터", "캐논블래스터": "캐논마스터",
        "매지션": "마법사", "아처": "궁수", "로그": "도적",
    ]

    /// "아크메이지(불,독)" 처럼 그대로 들어오거나, 공백·전각괄호가 섞여도 맞춘다. 1~3차 이름은 4차로 올려서 찾는다.
    static func entry(forJob job: String) -> Entry? {
        var key = job.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "（", with: "(").replacingOccurrences(of: "）", with: ")")
        if let a = aliases[key] { key = a }
        if let e = table[key] { return e }
        // 1차(전사/마법사/궁수/도적/해적): 계열 페이지 전체
        switch key {
        case "전사": return Entry(slugs: ["warrior"])
        case "마법사": return Entry(slugs: ["magician"])
        case "궁수": return Entry(slugs: ["archer"])
        case "도적": return Entry(slugs: ["thief"])
        case "해적": return Entry(slugs: ["pirate"])
        default: break
        }
        // 마지막 수단: 접두어가 겹치는 항목. Dictionary 순회 순서는 매번 달라지므로
        // 긴 키부터 봐서 결과가 흔들리지 않게 한다.
        return table.sorted { $0.key.count == $1.key.count ? $0.key < $1.key : $0.key.count > $1.key.count }
            .first { key.hasPrefix($0.key) || $0.key.hasPrefix(key) }?.value
    }

    /// 직업 페이지에서 해당 전직 경로의 스킬만 가져온다.
    /// 계열 공용 5차(*-5th-job 페이지)는 다루지 않는다 — 직업 전용 스킬만 쓴다.
    static func skills(forJob job: String) async throws -> [EffectImporter.Skill] {
        guard let e = entry(forJob: job) else { throw PetError("'\(job)' 직업 페이지를 모릅니다") }
        var out: [EffectImporter.Skill] = []
        var seen = Set<String>()
        for page in e.pages {
            let list = EffectImporter.filter(try await EffectImporter.listSkills(pages: [page]),
                                             path: e.path, pathIndex: e.pathIndex)
            for s in list where seen.insert(s.name).inserted { out.append(s) }
        }
        return out
    }
}
