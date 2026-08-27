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
        var wiki: String? = nil   // maplestorywiki.net 페이지 이름 (한글 스킬명 매칭용)
        var pages: [URL] { slugs.map { URL(string: base + $0 + "/")! } }
    }

    static let table: [String: Entry] = [
        // 모험가
        "히어로": Entry(slugs: ["warrior", "warrior-5th-job"], path: "Hero", wiki: "Hero"),
        "팔라딘": Entry(slugs: ["warrior", "warrior-5th-job"], path: "Paladin", wiki: "Paladin"),
        "다크나이트": Entry(slugs: ["warrior", "warrior-5th-job"], path: "Dark Knight", wiki: "Dark Knight"),
        "아크메이지(불,독)": Entry(slugs: ["magician", "magician-5th-job"], path: "Arch Mage", pathIndex: 0, wiki: "Arch Mage (Fire, Poison)"),
        "아크메이지(썬,콜)": Entry(slugs: ["magician", "magician-5th-job"], path: "Arch Mage", pathIndex: 1, wiki: "Arch Mage (Ice, Lightning)"),
        "비숍": Entry(slugs: ["magician", "magician-5th-job"], path: "Bishop", wiki: "Bishop"),
        "보우마스터": Entry(slugs: ["archer", "archer-5th-job"], path: "Bowmaster", wiki: "Bowmaster"),
        "신궁": Entry(slugs: ["archer", "archer-5th-job"], path: "Marksman", wiki: "Marksman"),
        "패스파인더": Entry(slugs: ["pathfinder", "archer-5th-job"], wiki: "Pathfinder"),
        "나이트로드": Entry(slugs: ["thief", "thief-5th-job"], path: "Night Lord", wiki: "Night Lord"),
        "섀도어": Entry(slugs: ["thief", "thief-5th-job"], path: "Shadower", wiki: "Shadower"),
        "듀얼블레이드": Entry(slugs: ["dual-blade", "thief-5th-job"], wiki: "Dual Blade"),
        "바이퍼": Entry(slugs: ["pirate", "pirate-5th-job"], path: "Buccaneer", wiki: "Buccaneer"),
        "캡틴": Entry(slugs: ["pirate", "pirate-5th-job"], path: "Corsair", wiki: "Corsair"),
        "캐논슈터": Entry(slugs: ["cannoneer", "pirate-5th-job"], wiki: "Cannoneer"),
        "초보자": Entry(slugs: ["explorer"]),
        // 시그너스
        "소울마스터": Entry(slugs: ["dawn-warrior", "warrior-5th-job"], wiki: "Dawn Warrior"), "플레임위자드": Entry(slugs: ["blaze-wizard", "magician-5th-job"], wiki: "Blaze Wizard"),
        "윈드브레이커": Entry(slugs: ["wind-archer", "archer-5th-job"], wiki: "Wind Archer"), "나이트워커": Entry(slugs: ["night-walker", "thief-5th-job"], wiki: "Night Walker"),
        "스트라이커": Entry(slugs: ["thunder-breaker", "pirate-5th-job"], wiki: "Thunder Breaker"), "미하일": Entry(slugs: ["mihile", "warrior-5th-job"], wiki: "Mihile"),
        "노블레스": Entry(slugs: ["noblesse"]),
        // 영웅
        "아란": Entry(slugs: ["aran", "warrior-5th-job"], wiki: "Aran"), "에반": Entry(slugs: ["evan", "magician-5th-job"], wiki: "Evan"),
        "메르세데스": Entry(slugs: ["mercedes", "archer-5th-job"], wiki: "Mercedes"), "팬텀": Entry(slugs: ["phantom", "thief-5th-job"], wiki: "Phantom"),
        "루미너스": Entry(slugs: ["luminous", "magician-5th-job"], wiki: "Luminous"), "은월": Entry(slugs: ["shade", "pirate-5th-job"], wiki: "Shade"),
        // 레지스탕스
        "배틀메이지": Entry(slugs: ["battle-mage", "magician-5th-job"], wiki: "Battle Mage"), "와일드헌터": Entry(slugs: ["wild-hunter", "archer-5th-job"], wiki: "Wild Hunter"),
        "메카닉": Entry(slugs: ["mechanic", "pirate-5th-job"], wiki: "Mechanic"), "데몬슬레이어": Entry(slugs: ["demon-slayer", "warrior-5th-job"], wiki: "Demon Slayer"),
        "데몬어벤져": Entry(slugs: ["demon-avenger", "warrior-5th-job"], wiki: "Demon Avenger"), "제논": Entry(slugs: ["xenon", "thief-5th-job"], wiki: "Xenon"),
        "블래스터": Entry(slugs: ["blaster", "warrior-5th-job"], wiki: "Blaster"), "시티즌": Entry(slugs: ["citizen"]), "데몬": Entry(slugs: ["demon"]),
        // 노바
        "카이저": Entry(slugs: ["kaiser", "warrior-5th-job"], wiki: "Kaiser"), "카인": Entry(slugs: ["kain", "archer-5th-job"], wiki: "Kain"),
        "카데나": Entry(slugs: ["cadena", "thief-5th-job"], wiki: "Cadena"), "엔젤릭버스터": Entry(slugs: ["angelic-buster", "pirate-5th-job"], wiki: "Angelic Buster"),
        // 레프
        "일리움": Entry(slugs: ["illium", "magician-5th-job"], wiki: "Illium"), "아크": Entry(slugs: ["ark", "pirate-5th-job"], wiki: "Ark"),
        "아델": Entry(slugs: ["adele", "warrior-5th-job"], wiki: "Adele"), "칼리": Entry(slugs: ["khali", "thief-5th-job"], wiki: "Khali"),
        // 아니마
        "호영": Entry(slugs: ["hoyoung", "thief-5th-job"], wiki: "Hoyoung"), "라라": Entry(slugs: ["lara", "magician-5th-job"], wiki: "Lara"),
        // 기타
        "제로": Entry(slugs: ["zero", "warrior-5th-job"], wiki: "Zero"), "키네시스": Entry(slugs: ["kinesis", "magician-5th-job"], wiki: "Kinesis"),
        "하야토": Entry(slugs: ["hayato"], wiki: "Hayato"), "칸나": Entry(slugs: ["kanna"], wiki: "Kanna"), "젯트": Entry(slugs: ["jett"], wiki: "Jett"), "제트": Entry(slugs: ["jett"], wiki: "Jett"),
        "비스트테이머": Entry(slugs: ["beast-tamer"], wiki: "Beast Tamer"), "모쿠아": Entry(slugs: ["mo-xuan"]), "젠": Entry(slugs: ["zen"]),
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
        "세미듀어러": "듀얼블레이드", "듀어러": "듀얼블레이드", "듀얼마스터": "듀얼블레이드", "슬래셔": "듀얼블레이드",
        "인파이터": "바이퍼", "버커니어": "바이퍼",
        "건슬링거": "캡틴", "발키리": "캡틴",
        "캐논슈터": "캐논슈터", "캐논블래스터": "캐논슈터",
        "매지션": "마법사", "아처": "궁수", "로그": "도적",
    ]

    /// "아크메이지(불,독)" 처럼 그대로 들어오거나, 공백·전각괄호가 섞여도 맞춘다. 1~3차 이름은 4차로 올려서 찾는다.
    static func entry(forJob job: String) -> Entry? {
        var key = job.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "（", with: "(").replacingOccurrences(of: "）", with: ")")
        if let a = aliases[key] { key = a }
        if let e = table[key] { return e }
        // 1차(전사/마법사/궁수/도적/해적): 계열 페이지 전체
        switch key {
        case "전사": return Entry(slugs: ["warrior"], wiki: "Warrior")
        case "마법사": return Entry(slugs: ["magician"], wiki: "Magician")
        case "궁수": return Entry(slugs: ["archer"], wiki: "Bowman")
        case "도적": return Entry(slugs: ["thief"], wiki: "Thief")
        case "해적": return Entry(slugs: ["pirate"], wiki: "Pirate")
        default: break
        }
        return table.first { key.hasPrefix($0.key) || $0.key.hasPrefix(key) }?.value
    }

    /// 직업의 스킬(공용 + 해당 경로)만 가져온다.
    /// 5차 공용 페이지(*-5th-job)는 직업 구분이 없어서, 위키 직업 스킬 목록(SkillNames.known)에 있는 이름만 남긴다.
    static func skills(forJob job: String) async throws -> [EffectImporter.Skill] {
        guard let e = entry(forJob: job) else { throw PetError("'\(job)' 직업 페이지를 모릅니다") }
        var out: [EffectImporter.Skill] = []
        var seen = Set<String>()
        for page in e.pages {
            let isCommon = page.path.contains("5th-job")
            var list = try await EffectImporter.listSkills(pages: [page])
            list = EffectImporter.filter(list, path: e.path, pathIndex: e.pathIndex)
            if isCommon, SkillNames.hasKnownList {
                list = list.filter { SkillNames.isKnownSkill($0.split.skill) }
            }
            for s in list where seen.insert(s.name).inserted { out.append(s) }
        }
        return out
    }
}
