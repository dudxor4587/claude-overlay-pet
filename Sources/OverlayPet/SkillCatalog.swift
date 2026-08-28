import Foundation

/// 캐릭터의 직업 스킬 목록을 만든다.
///   넥슨: 캐릭터가 배운 스킬 이름(한글) — 직업 판별과 5차 스킬 선별에 쓴다
///   KMS WZ: 그 직업의 스킬과 이펙트 조각
/// 결과는 pets/<id>/skills.json 에 캐시해 두 번째부터는 넥슨을 다시 부르지 않는다.
enum SkillCatalog {
    struct Cached: Codable {
        var job: String
        var jobImage: String
        var ownedNames: [String]
        var ts: Double
    }

    static func cacheURL(_ petId: String) -> URL {
        Paths.petDirectory(petId).appendingPathComponent("skills.json")
    }

    static func loadCache(_ petId: String?) -> Cached? {
        guard let petId, let d = try? Data(contentsOf: cacheURL(petId)),
              let c = try? JSONDecoder().decode(Cached.self, from: d) else { return nil }
        return c
    }

    static func saveCache(_ petId: String?, _ c: Cached) {
        guard let petId else { return }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? Paths.atomicWrite(try enc.encode(c), to: cacheURL(petId))
    }

    /// 직업 img 와 캐릭터가 가진 스킬 이름을 확보한다 (캐시 우선).
    static func resolve(petId: String?, job: String, progress: @escaping (String) -> Void) async throws -> (jobImage: String, owned: Set<String>) {
        if let c = loadCache(petId), c.job == job { return (c.jobImage, Set(c.ownedNames)) }

        guard let petId, let m = try? PetManifest.load(petId: petId) else {
            throw PetError("펫 정보를 읽지 못했습니다")
        }
        // 5차 스킬은 WZ 에 계열(도적 전체)로만 묶여 있어 직업 구분이 없다.
        // 캐릭터가 배운 5차 목록을 넥슨에서 한 번만 받아 그 직업 것만 남긴다.
        var owned = Set<String>()
        var fourth: [String] = []
        if let apiKey = APIKey.resolve(), let ocid = m.ocid {
            progress("5차 스킬 목록 확인 중…")
            let byGrade = await NexonClient.characterSkills(ocid: ocid, apiKey: apiKey,
                                                            grades: JobCodes.image(forJob: job) == nil ? ["4", "5"] : ["5"])
            owned = Set(byGrade["5"] ?? [])
            fourth = byGrade["4"] ?? []
        }

        let img: String
        if let known = JobCodes.image(forJob: job) { img = known }
        else { img = try await MapleWZ.resolveJobImage(job: job, fourthSkills: fourth, progress: progress) }

        saveCache(petId, Cached(job: job, jobImage: img, ownedNames: Array(owned).sorted(), ts: Date().timeIntervalSince1970))
        return (img, owned)
    }

    /// 고른 스킬 설치. 서버가 못 여는 캔버스(5차 공용 버킷 등)에 걸린 스킬은 즉시 건너뛴다.
    static func install(picked: [MapleWZ.Skill], petId: String?, job: String,
                        progress: @escaping (String) -> Void) async -> [String] {
        MapleWZ.loadAvailability()
        var names: [String] = []
        var skipped: [String] = []

        var failedNames = Set<String>()
        var triedFallback = Set<String>()
        var passive: [String] = []       // 이펙트 자체가 없는 스킬 (패시브 등)
        for (i, s) in picked.enumerated() {
            // 이미 "못 받는다" 고 확인된 스킬: 그 파일의 이전 버전 폴백을 (실행당 한 번) 찾아보고, 없으면 건너뛴다
            if MapleWZ.isBadSkill(s.id), MapleWZ.versionOverride(forImg: s.img) == nil {
                if triedFallback.contains(s.img) { skipped.append(s.name); continue }
                triedFallback.insert(s.img)
                guard let sample = await EffectImporter.samplePath(of: s) else { skipped.append(s.name); continue }
                guard await MapleWZ.establishFallback(forImg: s.img, samplePath: sample, progress: progress) else { skipped.append(s.name); continue }
            }
            // 한 스킬이 WZ 에 ID 여러 개로 쪼개져 있다(강화 단계·하이퍼 부속). 하나가 실패하면 이번 실행에선 나머지를 건너뛰되,
            // 부속 ID 는 내용이 다를 수 있으므로(나이트메어 31141503 은 별도 effect/screen) 시도 없이 "불가" 로 기록하지 않는다.
            if failedNames.contains(s.name) { skipped.append(s.name); continue }
            progress("\(i + 1)/\(picked.count) \(s.name)")
            var parts = await EffectImporter.animationsOrNil(of: s)
            var got: [String] = []
            if let p = parts, !p.isEmpty { got = await EffectImporter.installAll(p) { progress($0) } }
            if got.isEmpty, parts?.isEmpty != true {
                // 최신 버전에서 못 읽음 — 이 파일이 서버에서 깨진 것일 수 있으니 이전 버전을 찾아본다
                if let sample = await EffectImporter.samplePath(of: s),
                   await MapleWZ.establishFallback(forImg: s.img, samplePath: sample, progress: progress) {
                    parts = await EffectImporter.animationsOrNil(of: s)
                    if let p = parts, !p.isEmpty { got = await EffectImporter.installAll(p) { progress($0) } }
                }
            }
            if !got.isEmpty { names += got; continue }
            if parts?.isEmpty == true { passive.append(s.name); continue }   // 이펙트 없는 스킬
            skipped.append(s.name); failedNames.insert(s.name)
            // 스킬 노드 자체를 못 읽으면 서버 문제라 기록하지 않는다
            if let sample = await EffectImporter.samplePath(of: s) {
                await MapleWZ.confirmUnavailable(skillId: s.id, samplePath: sample)
            }
        }
        // 같은 스킬이 WZ 에 ID 여러 개로 쪼개져 있어서(강화 단계) 이름으로 묶어 센다
        let unique = Array(NSOrderedSet(array: skipped)) as? [String] ?? []
        let noFx = Array(NSOrderedSet(array: passive)) as? [String] ?? []
        if !unique.isEmpty {
            progress("받을 수 없는 스킬: " + unique.prefix(3).joined(separator: ", ")
                     + (unique.count > 3 ? " 외 \(unique.count - 3)개" : ""))
        }
        if !noFx.isEmpty {
            progress("이펙트가 없는 스킬(패시브): " + noFx.prefix(3).joined(separator: ", ")
                     + (noFx.count > 3 ? " 외 \(noFx.count - 3)개" : ""))
        }
        return names.sorted()
    }

    /// 직업의 전 차수 스킬 목록 (이름만 — 이펙트 조각은 고른 뒤에 찾는다)
    static func load(petId: String?, job: String, progress: @escaping (String) -> Void) async throws -> [MapleWZ.Skill] {
        let (img, owned) = try await resolve(petId: petId, job: job, progress: progress)
        let skills = try await MapleWZ.skills(jobImage: img, ownedNames: owned, progress: progress)
        guard !skills.isEmpty else { throw PetError("'\(job)' 스킬 데이터가 비어 있습니다") }
        // 목록 단계에서 미리 확인하지 않는다.
        // `_Canvas` 는 첫 접근이 수십 초 걸릴 수 있어(콜드) 짧게 찔러보면 멀쩡한 직업까지 불가로 오판한다.
        // 대신 실제로 받다가 실패하면 그 img 를 기록해 두고, 5차 버킷은 전 직업 공용이라 한 번만 겪는다.
        MapleWZ.loadAvailability()
        return skills.sorted { ($0.tierOrder, $0.name) < ($1.tierOrder, $1.name) }
    }
}
