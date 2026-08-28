import Foundation
import CoreGraphics

/// 이펙트 레이어. 에셋은 사용자가 직접 넣는다:
///   ~/.claude/pet/effects/<name>/effect.json + sheet.png
/// effect.json 예:
///   {"frameWidth":200,"frameHeight":200,"frames":12,"columns":6,"fps":12,
///    "loop":false,"anchor":"center","offsetX":0,"offsetY":40,"scale":1}
/// 공식 API 로 스킬 이펙트를 받을 수 있게 되면 fetcher 가 같은 포맷으로 떨어뜨리면 된다.
struct EffectManifest: Codable {
    var frameWidth: Int
    var frameHeight: Int
    var frames: Int
    var columns: Int?
    var fps: Double = 12
    var loop: Bool = false
    /// "center" | "bottom" — 캐릭터 기준 정렬
    var anchor: String = "center"
    var offsetX: Double = 0
    var offsetY: Double = 0
    var scale: Double = 1
    var sheetPath: String = "sheet.png"
    /// WZ origin 기준점 (셀 안 픽셀). 이 점이 캐릭터 발밑 중앙에 오도록 그린다.
    var anchorX: Double?
    var anchorY: Double?
    /// 프레임별 재생 시간(ms). 없으면 fps 로 균등 재생.
    var delays: [Int]?
    // 메뉴 표시용 메타 (가져오기 시 기록)
    var skill: String?
    var variant: String?
    var tier: String?
    var tierOrder: Int?
    var path: String?
    var skillId: String?
    /// 연속기 타수 — 타격 조각을 이만큼 반복 재생한다
    var hitCount: Int?
}

/// 설치된 이펙트의 매니페스트만 (시트는 안 읽음) — 메뉴 구성용
struct EffectInfo {
    let name: String
    let manifest: EffectManifest
    var tier: String { manifest.tier ?? "기타" }
    var tierOrder: Int { manifest.tierOrder ?? 99 }
    var skill: String { manifest.skill ?? name }
    /// 메뉴 표시용: 한글 이름이 있으면 한글, 없으면 영문
    var skillTitle: String { skill }
    var variant: String { manifest.variant ?? "" }

    static func all() -> [EffectInfo] {
        Effect.installed().compactMap { name in
            guard let data = try? Data(contentsOf: Paths.effectDirectory(name).appendingPathComponent("effect.json")),
                  let m = try? JSONDecoder().decode(EffectManifest.self, from: data) else { return nil }
            return EffectInfo(name: name, manifest: m)
        }
    }
}

struct Effect {
    let name: String
    let manifest: EffectManifest
    let image: CGImage
    var columns: Int { manifest.columns ?? max(1, image.width / manifest.frameWidth) }

    func contentsRect(frame: Int) -> CGRect {
        let c = frame % columns, r = frame / columns
        return CGRect(x: CGFloat(c * manifest.frameWidth) / CGFloat(image.width),
                      y: CGFloat(r * manifest.frameHeight) / CGFloat(image.height),
                      width: CGFloat(manifest.frameWidth) / CGFloat(image.width),
                      height: CGFloat(manifest.frameHeight) / CGFloat(image.height))
    }

    static func load(name: String) throws -> Effect {
        let dir = Paths.effectDirectory(name)
        let manifest = try JSONDecoder().decode(EffectManifest.self, from: Data(contentsOf: dir.appendingPathComponent("effect.json")))
        guard let image = SpriteSheet.loadImage(dir.appendingPathComponent(manifest.sheetPath)) else {
            throw PetError("이펙트 시트를 읽을 수 없음: \(name)")
        }
        return Effect(name: name, manifest: manifest, image: image)
    }

    static func installed() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: Paths.effects.path)) ?? [])
            .filter { FileManager.default.fileExists(atPath: Paths.effectDirectory($0).appendingPathComponent("effect.json").path) }
            .sorted()
    }
}

/// 스킬 조각들을 게임 순서대로 배치한다. 변형 이름 어휘는 전 직업 공통(WZ 구조)이라 직업별 예외가 없다.
///   선행(Prepare/Charge) → 본동작(Keydown/Loop/Repeat, 차례로) → 마무리(Keydown End/End)
///   Effect/Special/Ball/Screen/FX 는 본동작과 동시, Tile 은 순차로 앞으로 퍼지고, Hit/Mob 은 살짝 늦게 앞쪽.
///   Summon 계열(소환수 상태)은 "전체"에서 제외.
enum EffectSequencer {
    struct Item { let effect: Effect; let delay: Double; let offsetX: Double }

    enum Kind { case prepare, main, end, tile, hit, concurrent, summon }

    static func kind(of e: Effect) -> Kind {
        let v = (e.manifest.variant ?? "").lowercased().replacingOccurrences(of: " ", with: "")
        if v.contains("summon") || v.contains("소환") { return .summon }
        if v.hasPrefix("준비") || v.hasPrefix("prepare") || v.hasPrefix("charge") { return v.contains("hit") ? .hit : .prepare }
        if v.hasPrefix("holding끝") || v.hasPrefix("keydownend") || v.hasPrefix("end") { return .end }
        if v.hasPrefix("holding") || v.hasPrefix("반복") || v.hasPrefix("keydown") || v.hasPrefix("loop") || v.hasPrefix("repeat") { return .main }
        if v.hasPrefix("장판") || v.hasPrefix("tile") { return .tile }
        if v.hasPrefix("타격") || v.hasPrefix("몹") || v.hasPrefix("피격")
            || v.hasPrefix("hit") || v.hasPrefix("mob") || v.contains("hit") || v.hasPrefix("affected") { return .hit }
        return .concurrent   // 시전, 연출, 탄, 섬광, (없음) …
    }

    static func isSummon(_ e: Effect) -> Bool { kind(of: e) == .summon }

    static func plan(_ effects: [Effect]) -> [Item] {
        func v(_ e: Effect) -> String { (e.manifest.variant ?? "").lowercased() }
        func dur(_ e: Effect) -> Double {
            if let d = e.manifest.delays, !d.isEmpty { return Double(d.reduce(0, +)) / 1000 }
            return Double(e.manifest.frames) / max(1, e.manifest.fps)
        }
        func num(_ e: Effect) -> Int { Int(v(e).filter(\.isNumber)) ?? 0 }
        func ordered(_ k: Kind) -> [Effect] { effects.filter { kind(of: $0) == k }.sorted { (num($0), v($0)) < (num($1), v($1)) } }

        // WZ 에 있는 순서 정보는 프레임별 delay 뿐이다. 조각 사이 순서는
        //   준비/차지 → holding/반복 → 끝
        // 이 정도만 확실하고, 나머지는 동시에 시작한다. 위치는 origin 이 이미 정확하므로 건드리지 않는다.
        var items: [Item] = []
        var t = 0.0
        for p in ordered(.prepare) { items.append(Item(effect: p, delay: t, offsetX: 0)); t += dur(p) }
        let mainStart = t
        // holding/keydown 조각은 키를 누르고 있는 동안 도는 루프라 한 번만 재생하면 깜빡이고 만다. 최소 이 시간만큼 반복한다.
        let hold = 1.5
        for k in ordered(.main) {
            let d = max(dur(k), 0.05), loops = max(1, Int((hold / d).rounded(.up)))
            for _ in 0..<loops { items.append(Item(effect: k, delay: t, offsetX: 0)); t += d }
        }
        for k in ordered(.end) { items.append(Item(effect: k, delay: t, offsetX: 0)); t += dur(k) }

        // 시전: 같은 스킬 ID 안의 effect / effect2 는 같은 동작의 색 변형(일반/강화)이라 하나만 쓴다.
        // 스킬 ID 가 여럿이면 서로 다른 타의 동작이므로(암살 1·2타 / 3타) 차례로 잇는다.
        let casts = ordered(.concurrent).filter { v($0).hasPrefix("시전") }
        let extras = ordered(.concurrent).filter { !v($0).hasPrefix("시전") }
        var byId: [String: [Effect]] = [:]
        for c in casts { byId[c.manifest.skillId ?? c.name, default: []].append(c) }
        // 타격(hit/mob)은 원래 몬스터 자리에 그려지는 조각이라 기준점이 캐릭터와 맞지 않는다.
        // 몬스터가 없는 오버레이에서는 어디에 놓아도 어색해서 재생하지 않는다.
        var at = mainStart
        for key in byId.keys.sorted() {
            let vs = byId[key]!
            // 같은 스킬 ID 의 시전 변형이 "색만 다른 강화판"인지 "별도 레이어"인지는 이름이 아니라 데이터로 가른다:
            //   프레임 수·셀 크기·기준점이 기본형과 같으면 색 변형 → 하나만
            //   다르면 다른 동작(시전 자세, 장판 등) → 겹쳐 그린다
            let base = vs.first { v($0) == "시전" } ?? vs.first { v($0).hasPrefix("시전") }
            func sameShape(_ a: Effect, _ b: Effect) -> Bool {
                let m = a.manifest, n = b.manifest
                return m.frames == n.frames
                    && abs(m.frameWidth - n.frameWidth) <= 2 && abs(m.frameHeight - n.frameHeight) <= 2
                    && abs((m.anchorX ?? 0) - (n.anchorX ?? 0)) <= 2 && abs((m.anchorY ?? 0) - (n.anchorY ?? 0)) <= 2
            }
            let layered = vs.filter { e in
                guard let base, e.name != base.name else { return true }
                return !sameShape(e, base)
            }
            var longest = 0.0
            for e in layered { items.append(Item(effect: e, delay: at, offsetX: 0)); longest = max(longest, dur(e)) }
            // GMS 는 이 조각들이 한 애니메이션으로 이어 붙어 있다 (암살: 10 + 11 = 20프레임).
            // 앞 조각이 끝나고 조금 쉰 뒤 다음 타로 넘어간다.
            at += longest + 0.12
        }
        for r in extras { items.append(Item(effect: r, delay: mainStart, offsetX: 0)) }
        for (i, tile) in ordered(.tile).enumerated() { items.append(Item(effect: tile, delay: mainStart + 0.06 * Double(i), offsetX: 0)) }
        return items
    }
}
