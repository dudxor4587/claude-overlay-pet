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
    /// WZ `invisible` — 스킬창에 안 보이는 하위 스킬 (연속기 다음 타·각성판·소환수 등)
    var hidden: Bool?
    /// WZ `summon` — 소환수를 두는 스킬
    var summons: Bool?
    /// 스킬 설명 (String/Skill.img/<id>/desc) — 메뉴 툴팁
    var desc: String?
    /// 메타 스키마 버전. 낮으면 다시 받을 때 시트는 두고 이 값들만 채운다.
    var v: Int?
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

/// 재생 순서를 가르는 데 필요한 최소 정보 — 로드된 Effect 와 매니페스트만 읽은 EffectInfo 둘 다 만족한다.
protocol EffectPiece {
    var pieceId: String { get }        // 스킬 ID
    var pieceVariant: String { get }   // "시전", "holding", "준비" …
    var pieceHidden: Bool { get }      // WZ invisible — 스킬창에 없는 하위 스킬
    var pieceSummons: Bool { get }     // WZ summon — 소환수를 두는 스킬
}

extension Effect: EffectPiece {
    var pieceId: String { manifest.skillId ?? name }
    var pieceVariant: String { manifest.variant ?? "" }
    var pieceHidden: Bool { manifest.hidden ?? false }
    var pieceSummons: Bool { manifest.summons ?? false }
}

extension EffectInfo: EffectPiece {
    var pieceId: String { manifest.skillId ?? name }
    var pieceVariant: String { variant }
    var pieceHidden: Bool { manifest.hidden ?? false }
    var pieceSummons: Bool { manifest.summons ?? false }
}

/// 스킬 조각들을 게임 순서대로 배치한다. 변형 이름 어휘는 전 직업 공통(WZ 구조)이라 직업별 예외가 없다.
///   선행(Prepare/Charge) → 본동작(Keydown/Loop/Repeat, 차례로) → 마무리(Keydown End/End)
///   Effect/Special/Ball/Screen/FX 는 본동작과 동시, Tile 은 순차로 앞으로 퍼지고, Hit/Mob 은 살짝 늦게 앞쪽.
///   Summon 계열은 소환수 대기(stand)만 가져와 시전이 끝난 뒤 잠시 세운다.
enum EffectSequencer {
    /// loops: 같은 조각을 이어서 몇 번 도는지 (키다운 루프). 조각을 여러 개로 쪼개면
    /// 전환마다 새 레이어가 뜨면서 이음매가 보여서, 한 조각을 그대로 반복하게 한다.
    struct Item { let effect: Effect; let delay: Double; let offsetX: Double; var loops: Int = 1 }

    enum Kind { case prepare, main, end, tile, hit, concurrent, summon }

    static func kind(of e: Effect) -> Kind { kind(ofVariant: e.manifest.variant ?? "") }

    static func kind(ofVariant variant: String) -> Kind {
        let v = variant.lowercased().replacingOccurrences(of: " ", with: "")
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

    /// 이름이 같은 조각들을 "이어 재생할 한 벌" 단위로 가른다.
    /// WZ 는 한 한글 이름 아래에 스킬 ID 를 여럿 두는데, 성격이 네 가지로 갈린다:
    ///   ① 연속기의 다음 타      — 이어 재생해야 한다 (데몬 슬래시 VI 31141002~005)
    ///   ② 서로 대체되는 형태    — 하나만 (데몬 베인: 일반 400011110 / 각성 400011111)
    ///   ③ 버프가 거는 별개 공격 — 시전과 따로 (데몬 어웨이크닝 400011006 버프 + 007·008·009·018 각성 슬래시)
    ///   ④ 소환수 ID            — 캐릭터 기준 조각(특수 등)은 소환수 자리 기준이라 버리고,
    ///                            소환수 자신(stand)만 남겨 시전 뒤에 붙인다
    /// 가르는 신호는 WZ 노드에 다 있다:
    ///   invisible = 스킬창에 없는 하위 스킬 (①②③④ 모두 해당하므로 이것만으론 못 가른다)
    ///   summon    = 소환수를 둔다. 숨김 ID 에 붙으면 ④, 보이는 부모에 붙으면 그 부모는 버프라 ③
    ///   keydown 한 벌이 ID 마다 완결 = ② (키다운 스킬은 다른 키다운 스킬로 이어질 수 없다)
    /// 쓸 조각이 하나도 안 남으면 빈 배열 — 부르는 쪽이 그 스킬을 메뉴에서 뺀다.
    static func forms<T: EffectPiece>(_ pieces: [T]) -> [(id: String, pieces: [T])] {
        // 소환수는 ID 여럿이 같은 것을 중복으로 들고 있다 (오르트로스 077·078). 스킬당 하나만 쓴다.
        let creature = pieces.filter { kind(ofVariant: $0.pieceVariant) == .summon }
            .sorted { $0.pieceId < $1.pieceId }.prefix(1)
        let cast = pieces.filter { kind(ofVariant: $0.pieceVariant) != .summon }

        var byId: [String: [T]] = [:]
        for p in cast { byId[p.pieceId, default: []].append(p) }
        func any(_ id: String, _ test: (T) -> Bool) -> Bool { byId[id]!.contains(where: test) }

        // ④ 소환수 ID 가 들고 있는 캐릭터 기준 조각은 버린다 (스파이더 인 미러의 특수 0/1/2)
        let ids = byId.keys.sorted().filter { !(any($0) { $0.pieceHidden } && any($0) { $0.pieceSummons }) }

        func result(_ groups: [(id: String, pieces: [T])]) -> [(id: String, pieces: [T])] {
            guard var first = groups.first else {
                return creature.isEmpty ? [] : [(id: creature[0].pieceId, pieces: Array(creature))]
            }
            first.pieces += creature          // 소환수는 첫 항목(시전) 뒤에 붙는다
            return [first] + groups.dropFirst()
        }

        guard let head = ids.first else { return result([]) }
        guard ids.count >= 2 else { return result([(id: head, pieces: byId[head]!)]) }

        // ② 준비/holding/끝 한 벌이 ID 마다 완결돼 있으면 이어 붙일 수 없는 별개 형태다
        let keydown = ids.filter { any($0) { kind(ofVariant: $0.pieceVariant) == .main } }
        if keydown.count >= 2 {
            let shared = ids.filter { !keydown.contains($0) }.flatMap { byId[$0]! }
            return result(keydown.map { (id: $0, pieces: byId[$0]! + shared) })
        }

        // ③ 보이는 부모가 소환수를 두면 버프 — 숨김 하위는 시전의 뒷부분이 아니라 별개 공격이다
        let hidden = ids.filter { any($0) { $0.pieceHidden } }
        let visible = ids.filter { !any($0) { $0.pieceHidden } }
        guard !hidden.isEmpty, let front = visible.first, visible.contains(where: { any($0) { $0.pieceSummons } }) else {
            return result([(id: head, pieces: ids.flatMap { byId[$0]! })])   // ① 연속기 — 이어 붙인다
        }
        return result([(id: front, pieces: visible.flatMap { byId[$0]! }),
                       (id: hidden[0], pieces: hidden.flatMap { byId[$0]! })])
    }

    static func plan(_ rawEffects: [Effect]) -> [Item] {
        // 대체 형태가 섞여 들어오면 (예전에 저장된 바인딩·갤러리) 첫 형태만 재생한다.
        let effects = Dictionary(grouping: rawEffects, by: { $0.manifest.skill ?? $0.name })
            .sorted { $0.key < $1.key }
            .flatMap { forms($0.value).first?.pieces ?? [] }
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
            items.append(Item(effect: k, delay: t, offsetX: 0, loops: loops))
            t += d * Double(loops)
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
        // 소환수는 시전이 끝난 뒤 나타난다. stand 는 게임에선 소환이 유지되는 내내 도는 무한 루프라
        // 한 바퀴만 돌리면 0.6초 만에 사라진다 — 이 시간만큼 반복하고 사라지게 한다.
        let linger = 3.0
        for c in ordered(.summon) {
            let d = max(dur(c), 0.05)
            items.append(Item(effect: c, delay: at, offsetX: 0, loops: max(1, Int((linger / d).rounded(.up)))))
        }
        for (i, tile) in ordered(.tile).enumerated() { items.append(Item(effect: tile, delay: mainStart + 0.06 * Double(i), offsetX: 0)) }
        return items
    }
}
