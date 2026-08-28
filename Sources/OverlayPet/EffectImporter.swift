import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// KMS WZ(Skill.wz)에서 스킬 이펙트를 받아 시트로 조립한다.
/// 한 스킬은 여러 애니메이션 조각(effect / hit / tile / keydown …)으로 나뉘어 있고,
/// 프레임마다 `origin`(기준점)과 `delay`(ms)가 있어 위치·타이밍을 그대로 재현할 수 있다.
/// 에셋은 사용자가 요청할 때 런타임에만 받는다. 레포에는 넣지 않는다.
enum EffectImporter {
    static let maxFrameSide = 512

    /// 애니메이션 한 덩어리 = 스킬의 조각 하나
    struct Skill {
        let skillId: String
        let skillName: String      // 한글
        let variant: String        // "시전", "타격 0", "장판 2" …
        let tier: String
        let tierOrder: Int
        let framePaths: [String]   // WZ 경로 (프레임 순)
        var hitCount: Int = 1      // common/attackCount — 연속기는 타격이 여러 번 들어간다

        /// 파일 이름 겸 고유 키
        var name: String { SheetBuilder.slug("\(skillName)-\(variant)-\(skillId)") }
        var split: (skill: String, variant: String) { (skillName, variant) }
        var displayName: String { variant.isEmpty ? skillName : "\(skillName) · \(variant)" }
        var frames: [String] { framePaths }
    }

    /// 애니메이션이 아닌 노드 (아이콘·수치·플래그)
    static let skipKeys: Set<String> = [
        "icon", "iconDisabled", "iconMouseOver", "info", "info2", "common", "PVPcommon", "level", "req",
        "combatOrders", "masterLevel", "psd", "psdSkill", "hyper", "reqLev", "action", "actionList",
        "string", "weapon", "skillType", "invisible", "number", "vSkill", "extraSkillInfo",
        "additional_process", "processtype", "notRemoved", "excl", "changeSkill", "addAttack",
        "disabledDuringAction", "isBeneficial", "isPetAutoBuff", "canNotStealableSkill", "exceedInfo",
        "notCooltimeReset", "notIncBuffDuration", "notRemoveEffectByCancelSkill", "notResetDarkSight",
        "invisibleEvenSkillLevel", "footholdAffectedArea", "footholdInstallSummoned",
    ]

    /// 캐릭터 기준으로 그려지는 노드만. 타격(hit)·몹(mob)·피격(affected)·탄(ball)은 몬스터 자리 기준이라 제외.
    /// special·tile 은 장판/버프처럼 캐릭터 발밑 origin 이 있어 함께 그린다 (베일 오브 섀도우 등).
    static func isCastKey(_ key: String) -> Bool {
        let k = key.lowercased()
        if k.hasPrefix("hit") || k.hasPrefix("mob") || k.contains("affected") || k.contains("summon") || k.hasPrefix("ball") { return false }
        if k == "effectflash" { return false }   // alpha/color 만 있는 화면 번쩍임 — 이미지가 없다
        return k.hasPrefix("effect") || k.hasPrefix("prepare") || k.hasPrefix("keydown")
            || k.hasPrefix("screen") || k.hasPrefix("charge") || k.hasPrefix("repeat") || k.hasPrefix("loop")
            || k.hasPrefix("special") || k.hasPrefix("tile")
    }

    /// WZ 키 → 사람이 읽을 이름
    static func label(_ key: String) -> String {
        switch key {
        case "effect": return "시전"
        case "effect0", "effect2", "effect3": return "시전 \(key.suffix(1))"
        case "hit": return "타격"
        case "hit2": return "타격 2"
        case "tile": return "장판"
        case "special": return "특수"
        case "screen": return "연출"
        case "screen2", "screen3": return "연출 \(key.suffix(1))"
        case "holding": return "holding"
        case "prepare": return "준비"
        case "keydown", "keyDown": return "holding"
        case "keydownEnd", "keyDownEnd": return "holding 끝"
        case "mob": return "몹"
        case "ball": return "탄"
        case "affected", "affected0": return "피격"
        case "effectFlash": return "섬광"
        case "repeat": return "반복"
        default: return key
        }
    }

    /// 스킬 하나의 애니메이션 조각을 모두 찾는다.
    /// - 직접: `effect/0,1,2…`
    /// - 중첩: `hit/0/0,1,2…` (같은 종류의 변형이 여럿)
    /// 스킬 노드를 못 읽었으면 nil (서버 문제), 읽었는데 이펙트 노드가 없으면 빈 배열 (패시브)
    /// 실패 재확인·폴백 탐색에 쓸 "이 스킬의 실제 첫 프레임" 경로.
    /// effect 가 없는 스킬(special/tile 만 있는 소환기 등)도 있으므로 effect/0 으로 고정하면 안 된다.
    static func samplePath(of s: MapleWZ.Skill) async -> String? {
        let base = "Skill/\(s.img).img/skill/\(s.id)"
        guard let ch = try? await MapleWZ.children(base) else { return nil }
        let keys = ch.filter { !skipKeys.contains($0) && isCastKey($0) }
        guard let key = keys.first(where: { $0 == "effect" }) ?? keys.first else { return nil }
        func numeric(_ xs: [String]) -> [String] { xs.filter { !$0.isEmpty && $0.allSatisfy(\.isNumber) }.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) } }
        guard let sub = try? await MapleWZ.children("\(base)/\(key)"), let first = numeric(sub).first else { return "\(base)/\(key)/0" }
        // 중첩(special/0/0…)이면 한 단계 더 내려간다
        if let inner = try? await MapleWZ.children("\(base)/\(key)/\(first)"), let f = numeric(inner).first, numeric(inner).count >= 2 {
            return "\(base)/\(key)/\(first)/\(f)"
        }
        return "\(base)/\(key)/\(first)"
    }

    static func animationsOrNil(of s: MapleWZ.Skill) async -> [Skill]? {
        let base = "Skill/\(s.img).img/skill/\(s.id)"
        var node: [String: Any]?
        for _ in 0..<2 {
            if let n = ((try? await MapleWZ.node(base)) ?? nil) { node = n; break }
        }
        guard let node else { return nil }
        let ch = (node["children"] as? [String]) ?? []
        let r = await scan(of: s, children: ch)
        if r.pieces.isEmpty && r.failed { return nil }   // 이펙트 노드는 있는데 못 읽음 → 실패
        return r.pieces
    }

    static func animations(of s: MapleWZ.Skill) async -> [Skill] {
        await animationsOrNil(of: s) ?? []
    }

    static func animations(of s: MapleWZ.Skill, children ch: [String]) async -> [Skill] {
        await scan(of: s, children: ch).pieces
    }

    /// pieces 가 비었어도 `failed` 가 true 면 서버에서 노드를 못 읽은 것이다 (패시브가 아니라 실패)
    static func scan(of s: MapleWZ.Skill, children ch: [String]) async -> (pieces: [Skill], failed: Bool) {
        let base = "Skill/\(s.img).img/skill/\(s.id)"
        let tier = s.tier
        let order = s.tierOrder
        // 연속기 타수 (타격 조각을 이만큼 반복 재생한다)
        var hits = 1
        if let v = (try? await MapleWZ.value("\(base)/common/attackCount")) {
            if let n = v as? Int { hits = n } else if let str = v as? String, let n = Int(str) { hits = n }
        }
        hits = max(1, min(hits, 12))

        func numeric(_ xs: [String]) -> [String] {
            xs.filter { !$0.isEmpty && $0.allSatisfy(\.isNumber) }.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }
        }

        // 시전(effect) 계열만 가져온다. 타격·장판·몹은 몬스터 자리 기준이라 오버레이에서 못 쓴다.
        let keys = ch.filter { !skipKeys.contains($0) && isCastKey($0) }
        var out: [Skill] = []
        var failed = false
        await withTaskGroup(of: [Skill]?.self) { group in
            var it = keys.makeIterator()
            func next() {
                guard let key = it.next() else { return }
                group.addTask {
                    // 자식 목록에 있는 이펙트 노드인데 내용이 비면(404·타임아웃) 읽기 실패다 — 패시브가 아니다
                    guard let sub = try? await MapleWZ.children("\(base)/\(key)"), !sub.isEmpty else { return nil }
                    let nums = numeric(sub)
                    guard !nums.isEmpty else { return [] }
                    // 중첩 여부: 첫 항목 아래에 프레임(숫자)이 또 있으면 변형이 여럿이다.
                    // hit/0 처럼 숫자 프레임과 플래그(randomHitAngle 등)가 섞여 있으므로 "전부 숫자"로 보면 안 된다.
                    // 첫 프레임 노드를 못 읽으면(타임아웃·404) 실패다 — "이미지 없음" 과 섞으면 패시브로 오판한다
                    guard let firstNode = ((try? await MapleWZ.node("\(base)/\(key)/\(nums[0])")) ?? nil) else { return nil }
                    let firstKids = (firstNode["children"] as? [String]) ?? []
                    let inner = numeric(firstKids)
                    // 이미지도 _outlink 도 없는 노드(alpha/color 만)는 스프라이트가 아니다
                    if inner.isEmpty, firstNode["value"] == nil, !firstKids.contains("_outlink") { return [] }
                    if inner.count >= 2 {
                        var made: [Skill] = []
                        for v in nums {
                            let frames = numeric((try? await MapleWZ.children("\(base)/\(key)/\(v)")) ?? [])
                            guard frames.count >= 2 else { continue }
                            made.append(Skill(skillId: s.id, skillName: s.name, variant: "\(label(key)) \(v)",
                                              tier: tier, tierOrder: order,
                                              framePaths: frames.map { "\(base)/\(key)/\(v)/\($0)" }, hitCount: hits))
                        }
                        return made
                    }
                    guard nums.count >= 2 else { return [] }
                    return [Skill(skillId: s.id, skillName: s.name, variant: label(key),
                                  tier: tier, tierOrder: order,
                                  framePaths: nums.map { "\(base)/\(key)/\($0)" }, hitCount: hits)]
                }
            }
            for _ in 0..<4 { next() }
            for await made in group {
                if let made { out += made } else { failed = true }
                next()
            }
        }
        return (out, failed)
    }

    /// 고른 스킬들의 애니메이션 조각 (목록 만들 때가 아니라 선택 후에 부른다)
    static func animations(for skills: [MapleWZ.Skill], progress: @escaping (String) -> Void) async -> [Skill] {
        // 같은 이름의 다른 ID 는 보통 1타/2타처럼 서로 다른 동작이라 지우지 않는다.
        var out: [Skill] = []
        var done = 0
        await withTaskGroup(of: [Skill].self) { group in
            var it = skills.makeIterator()
            func next() {
                guard let s = it.next() else { return }
                group.addTask {
                    await withTaskGroup(of: [Skill]?.self) { race in
                        race.addTask { await animations(of: s) }
                        race.addTask { try? await Task.sleep(nanoseconds: 10_000_000_000); return nil }
                        let first = await race.next() ?? nil
                        race.cancelAll()
                        return first ?? []
                    }
                }
            }
            for _ in 0..<6 { next() }
            for await xs in group {
                out += xs; done += 1
                progress("스킬 분석 \(done)/\(skills.count)")
                next()
            }
        }
        return out.sorted { ($0.tierOrder, $0.skillName, $0.variant) < ($1.tierOrder, $1.skillName, $1.variant) }
    }

    // MARK: - 프레임

    struct Frame {
        let png: Data
        let width: Int
        let height: Int
        let originX: Int
        let originY: Int
        let delay: Int
    }

    /// 프레임 한 장 = 이미지·origin·delay 세 노드. 순차로 기다리면 왕복이 3배라 동시에 받는다.
    static func loadFrame(_ path: String) async -> Frame? {
        async let nodeTask = MapleWZ.node(path)
        async let originTask = MapleWZ.value("\(path)/origin")
        async let delayTask = MapleWZ.value("\(path)/delay")
        guard let n = ((try? await nodeTask) ?? nil) else { return nil }
        var png = (n["value"] as? String).flatMap { Data(base64Encoded: $0) }
        func size(_ d: Data) -> (Int, Int) {
            (Int(d[16]) << 24 | Int(d[17]) << 16 | Int(d[18]) << 8 | Int(d[19]),
             Int(d[20]) << 24 | Int(d[21]) << 16 | Int(d[22]) << 8 | Int(d[23]))
        }
        // 값이 없거나 1x1 자리표시자면 실제 이미지는 _outlink 가 가리키는 _Canvas 에 있다.
        if png == nil || png!.count <= 24 || size(png!) == (1, 1) {
            if let link = (await MapleWZ.nodeFast("\(path)/_outlink"))?["value"] as? String {
                // 캔버스는 첫 접근이 느리다 — 실행당 한 번 데운 뒤에 짧게 받는다.
                // 프레임 하나가 잠깐 안 와도 캔버스 전체를 낙인찍지 않는다 (여러 스킬을 한 번에 받을 때 도미노로 실패하던 원인).
                guard await MapleWZ.warmCanvas(forOutlink: link) else { return nil }
                var got: Data?
                for _ in 0..<2 {
                    if let t = await MapleWZ.nodeFast(link, timeout: 6),
                       let b = (t["value"] as? String).flatMap({ Data(base64Encoded: $0) }), b.count > 24 { got = b; break }
                }
                guard let got else { return nil }
                png = got
            }
        }
        guard let png, png.count > 24 else { return nil }
        let (w, h) = size(png)
        guard w > 1, h > 1, w < 4000, h < 4000 else { return nil }
        var ox = w / 2, oy = h / 2, delay = 100
        if let o = ((try? await originTask) ?? nil) as? [String: Any] {
            ox = (o["x"] as? Int) ?? ox
            oy = (o["y"] as? Int) ?? oy
        }
        if let d = ((try? await delayTask) ?? nil) as? Int { delay = max(16, d) }
        return Frame(png: png, width: w, height: h, originX: ox, originY: oy, delay: delay)
    }

    /// 조각 하나를 받아 effects/<name>/ 에 설치. 반환: 이펙트 이름.
    static func install(_ skill: Skill, progress: @escaping (String) -> Void) async throws -> String {
        var frames = [Frame?](repeating: nil, count: skill.framePaths.count)
        var done = 0
        await withTaskGroup(of: (Int, Frame?).self) { group in
            var it = skill.framePaths.enumerated().makeIterator()
            func next() { if let (i, p) = it.next() { group.addTask { (i, await loadFrame(p)) } } }
            for _ in 0..<6 { next() }
            for await (i, f) in group {
                frames[i] = f; done += 1
                progress("\(skill.displayName) \(done)/\(skill.framePaths.count)")
                next()
            }
        }
        let fs = frames.compactMap { $0 }
        guard !fs.isEmpty else {
            // 프레임이 하나도 안 나오면 정말 못 받는지 확인 후 기록 (일시적 장애와 구분)
            if let sample = skill.framePaths.first {
                await MapleWZ.confirmUnavailable(skillId: skill.skillId, samplePath: sample)
            }
            throw PetError("프레임이 없습니다: \(skill.displayName)")
        }

        // origin 을 기준으로 모든 프레임을 한 좌표계에 맞춘다
        let left = fs.map(\.originX).max()!
        let top = fs.map(\.originY).max()!
        let right = fs.map { $0.width - $0.originX }.max()!
        let bottom = fs.map { $0.height - $0.originY }.max()!
        let rawW = max(1, left + right), rawH = max(1, top + bottom)
        let shrink = min(1.0, Double(maxFrameSide) / Double(max(rawW, rawH)))
        let cellW = max(1, Int((Double(rawW) * shrink).rounded())), cellH = max(1, Int((Double(rawH) * shrink).rounded()))
        let cols = min(fs.count, max(1, Int(ceil(sqrt(Double(fs.count))))))
        let rows = Int(ceil(Double(fs.count) / Double(cols)))

        guard let ctx = CGContext(data: nil, width: cellW * cols, height: cellH * rows, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw PetError("비트맵 생성 실패") }
        ctx.interpolationQuality = shrink < 1 ? .high : .none

        for (i, f) in fs.enumerated() {
            guard let src = CGImageSourceCreateWithData(f.png as CFData, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
            let c = i % cols, r = i / cols
            let w = Double(f.width) * shrink, h = Double(f.height) * shrink
            let x = Double(c * cellW) + (Double(left - f.originX)) * shrink
            // CG 는 아래가 원점 — 셀 위쪽 기준 좌표를 뒤집는다
            let yTop = Double(r * cellH) + (Double(top - f.originY)) * shrink
            ctx.draw(img, in: CGRect(x: x, y: Double(rows * cellH) - yTop - h, width: w, height: h))
        }
        guard let sheet = ctx.makeImage() else { throw PetError("시트 생성 실패") }

        let name = skill.name
        let dir = Paths.effectDirectory(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let png = dir.appendingPathComponent("sheet.png")
        guard let dst = CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw PetError("PNG 저장 실패")
        }
        CGImageDestinationAddImage(dst, sheet, nil)
        guard CGImageDestinationFinalize(dst) else { throw PetError("PNG 저장 실패") }

        var m = EffectManifest(frameWidth: cellW, frameHeight: cellH, frames: fs.count, columns: cols)
        m.anchorX = Double(left) * shrink
        m.anchorY = Double(top) * shrink
        m.delays = fs.map(\.delay)
        m.fps = 1000.0 / Double(max(16, fs.map(\.delay).reduce(0, +) / max(1, fs.count)))
        m.loop = false
        m.scale = 1 / shrink            // 줄여 저장한 만큼 표시할 때 되돌린다
        m.skill = skill.skillName
        m.variant = skill.variant
        m.tier = skill.tier
        m.tierOrder = skill.tierOrder
        m.skillId = skill.skillId
        m.hitCount = skill.hitCount
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(m).write(to: dir.appendingPathComponent("effect.json"))
        return name
    }

    /// 여러 조각 설치. 이미 있으면 건너뛴다.
    static func installAll(_ skills: [Skill], progress: @escaping (String) -> Void) async -> [String] {
        var names: [String] = []
        var done = 0, failed = 0
        var deadSkills = Set<String>()   // 조각 하나가 실패하면 그 스킬은 더 시도하지 않는다
        for s in skills {
            done += 1
            if deadSkills.contains(s.skillId) { continue }
            if FileManager.default.fileExists(atPath: Paths.effectDirectory(s.name).appendingPathComponent("effect.json").path) {
                names.append(s.name); continue
            }
            progress("\(done)/\(skills.count) \(s.displayName)")
            // 조각 하나가 서버 지연에 걸리면 통째로 붙잡히지 않게 상한을 둔다.
            // 총 시간이 아니라 "프레임 진행이 멈춘 시간" 기준 — 61프레임짜리 연출(screen)이 정상 진행 중인데 잘리면 안 된다.
            // 이전 버전 폴백 경로는 프레임당 10~20초가 걸리므로 더 넉넉히 둔다.
            let img = s.framePaths.first.flatMap(MapleWZ.imgOf) ?? ""
            let stall: TimeInterval = MapleWZ.versionOverride(forImg: img) != nil ? 60 : 20
            let pulse = Pulse()
            let installed: String? = await withTaskGroup(of: String??.self) { race in
                race.addTask {
                    do { return try await install(s, progress: { _ in pulse.beat() }) }
                    catch { progress("실패: \(s.displayName) — \(error.localizedDescription)"); return String?.none }
                }
                race.addTask {
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        if pulse.idle() > stall { return String?.none }
                    }
                    return String?.none
                }
                let first = await race.next() ?? nil
                race.cancelAll()
                return first ?? nil
            }
            if let installed {
                names.append(installed)
                MapleWZ.markAvailable(skillId: s.skillId)   // 받아졌으니 "받을 수 없음" 기록을 지운다
            } else {
                failed += 1
                deadSkills.insert(s.skillId)
                // 일시적 장애일 수 있으니 넉넉한 시간으로 한 번 더 확인한 뒤에만 "불가" 로 기록한다
                if let sample = s.framePaths.first {
                    await MapleWZ.confirmUnavailable(skillId: s.skillId, samplePath: sample)
                }
            }
        }
        if failed > 0 { progress("설치 완료 (실패 \(failed))") }
        return names.sorted()
    }
}

/// 마지막 진행 시각 — 정지 감시용
final class Pulse: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date()
    func beat() { lock.lock(); last = Date(); lock.unlock() }
    func idle() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(last) }
}
