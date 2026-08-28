import Foundation

/// maplestory.io 의 WZ 브라우저로 KMS 원본 데이터를 읽는다.
///   String/Skill.img/<스킬ID>/name          → 한글 스킬명
///   Skill/<직업img>/skill/<스킬ID>/effect/N → 프레임 PNG(base64) + delay(ms) + origin(x,y)
/// KMS 기준이라 GMS 이름 매칭이 필요 없고, origin·delay 가 있어 위치·타이밍이 정확하다.
/// 에셋은 사용자가 요청할 때 런타임에만 받는다. 레포에는 넣지 않는다.
enum MapleWZ {
    static let host = "https://maplestory.io/api/wz"
    static let region = "KMS"
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"

    // MARK: - 버전

    private static var cachedVersion: String?

    /// 준비된 KMS 버전 중 가장 최신. 하루 캐시.
    static func version() async throws -> String {
        if let v = cachedVersion { return v }
        if let c = VersionCache.load() { cachedVersion = c; return c }
        let (data, _) = try await URLSession.shared.data(for: request(URL(string: host)!))
        guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw PetError("WZ 버전 목록을 읽지 못했습니다")
        }
        let versions = list.compactMap { row -> Int? in
            guard row["region"] as? String == region, (row["isReady"] as? Bool) == true,
                  let v = row["mapleVersionId"] as? String, let n = Int(v) else { return nil }
            return n
        }
        guard let latest = versions.max() else { throw PetError("KMS 버전이 없습니다") }
        cachedVersion = String(latest)
        VersionCache.save(String(latest))
        return String(latest)
    }

    private enum VersionCache {
        static let url = Paths.root.appendingPathComponent("wz-version.json")
        struct Entry: Codable { var version: String; var ts: Double }
        static func load() -> String? {
            guard let d = try? Data(contentsOf: url), let e = try? JSONDecoder().decode(Entry.self, from: d),
                  Date().timeIntervalSince1970 - e.ts < 86400 else { return nil }
            return e.version
        }
        static func save(_ v: String) {
            let enc = JSONEncoder()
            try? Paths.ensureDirectories()
            try? Paths.atomicWrite(try enc.encode(Entry(version: v, ts: Date().timeIntervalSince1970)), to: url)
        }
    }

    // MARK: - 노드 읽기

    private static func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        r.timeoutInterval = 8   // 정상 응답은 0.05초대. 서버가 가끔 한 노드에서 수십 초를 끄는 걸 끊는다.
        return r
    }

    /// 서버가 가끔 500 을 뱉어서 재시도한다. 404 는 "없음"이므로 nil.
    /// 특정 img 파일이 최신 버전에서 깨져 있으면(서버 파서 오류) 그 파일만 이전 버전에서 읽는다. img → 버전
    private static var imgVersions: [String: String] = [:]
    static let imgVersionsURL = Paths.root.appendingPathComponent("img-versions.json")
    /// 폴백 후보: 서버가 가진 KMS 버전 중 현재보다 낮은 것을 최신부터 골라 쓴다 (특정 버전을 박아두지 않는다).
    /// 가까운 버전 3개 + 그 뒤로 4개씩 건너뛴 3개 — 깨진 파일은 대개 최근 몇 버전 사이에서 깨졌기 때문.
    private static var allVersions: [Int] = []
    static func fallbackVersions() async -> [String] {
        if allVersions.isEmpty, let (data, _) = try? await URLSession.shared.data(for: request(URL(string: host)!)),
           let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            allVersions = list.compactMap { row -> Int? in
                guard row["region"] as? String == region, (row["isReady"] as? Bool) == true,
                      let v = row["mapleVersionId"] as? String else { return nil }
                return Int(v)
            }.sorted(by: >)
        }
        guard let cur = Int((try? await version()) ?? "") else { return [] }
        let older = allVersions.filter { $0 < cur }
        var picked: [Int] = Array(older.prefix(3))
        var i = 3
        while picked.count < 6, i < older.count { picked.append(older[i]); i += 4 }
        return picked.map(String.init)
    }

    static func imgOf(_ path: String) -> String? {
        path.split(separator: "/").first { $0.hasSuffix(".img") }.map { String($0.dropLast(4)) }
    }
    static func versionOverride(forImg img: String) -> String? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return imgVersions[img]
    }
    static func setVersionOverride(_ v: String, forImg img: String) {
        cacheLock.lock(); imgVersions[img] = v; let snap = imgVersions; cacheLock.unlock()
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? Paths.ensureDirectories()
        try? Paths.atomicWrite(try enc.encode(snap), to: imgVersionsURL)
    }
    static func loadVersionOverrides() {
        guard let d = try? Data(contentsOf: imgVersionsURL), let m = try? JSONDecoder().decode([String: String].self, from: d) else { return }
        cacheLock.lock(); imgVersions.merge(m) { a, _ in a }; cacheLock.unlock()
    }

    /// 최신 버전에서 못 읽는 파일이면 이전 버전을 차례로 찔러 되는 버전을 기억한다. 성공 여부 반환.
    static func establishFallback(forImg img: String, samplePath: String, progress: (String) -> Void) async -> Bool {
        if versionOverride(forImg: img) != nil { return true }
        let candidates = await fallbackVersions()
        guard !candidates.isEmpty else { return false }
        progress("이전 버전(\(candidates.joined(separator: "·")))에서 동시에 시도 중…")
        // 깨진 버전은 500 을 주기까지 15~30초씩 걸린다. 하나씩 기다리면 몇 분이 되므로 동시에 찔러 최신 성공본을 고른다.
        var ok: [Int] = []
        await withTaskGroup(of: (String, Bool).self) { group in
            for v in candidates {
                // 자리표시자(1×1)만으로는 성공이 아니다 — 깨진 버전도 자리표시자는 준다. 실제 캔버스까지 받아져야 한다.
                group.addTask { (v, await realFrame(samplePath, version: v, timeout: 30)) }
            }
            for await (v, good) in group where good { if let n = Int(v) { ok.append(n) } }
        }
        guard let best = ok.max() else { return false }
        setVersionOverride(String(best), forImg: img)
        return true
    }

    /// 이 파일을 읽을 버전: 오버라이드가 있으면 그것, 아니면 최신
    static func versionFor(path: String) async throws -> String {
        if let img = imgOf(path), !path.hasPrefix("String/"), let v = versionOverride(forImg: img) { return v }
        return try await version()
    }

    static func node(_ path: String) async throws -> [String: Any]? {
        let v = try await versionFor(path: path)
        var comps = URLComponents(string: "\(host)/\(region)/\(v)/")!
        comps.path += path
        guard let url = comps.url else { throw PetError("잘못된 WZ 경로: \(path)") }
        var lastStatus = 0
        for attempt in 0..<2 {   // 타임아웃이면 한 번만 더
            if let (data, resp) = try? await URLSession.shared.data(for: request(url)) {
                lastStatus = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if lastStatus == 200 { return try? JSONSerialization.jsonObject(with: data) as? [String: Any] }
                if lastStatus == 404 { return nil }
            }
            try? await Task.sleep(nanoseconds: UInt64(150_000_000 * (attempt + 1)))
        }
        throw PetError("WZ 요청 실패 (\(lastStatus)) \(path)")
    }

    /// 재시도 없이 짧게 한 번만 — 죽은 캔버스를 빨리 판별할 때 쓴다.
    static func nodeFast(_ path: String, timeout: TimeInterval = 3, version forced: String? = nil) async -> [String: Any]? {
        var v: String? = forced
        if v == nil { v = try? await versionFor(path: path) }
        guard let v else { return nil }
        var c = URLComponents(string: "\(host)/\(region)/\(v)/")!
        c.path += path
        guard let url = c.url else { return nil }
        var r = URLRequest(url: url)
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        r.timeoutInterval = timeout
        guard let (data, resp) = try? await URLSession.shared.data(for: r),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func children(_ path: String) async throws -> [String] {
        (try await node(path))?["children"] as? [String] ?? []
    }

    static func value(_ path: String) async throws -> Any? {
        (try await node(path))?["value"]
    }

    /// `_Canvas/<img>` 는 서버가 처음 열 때 30초 넘게 걸리고(콜드) 그 뒤엔 즉시 응답한다.
    /// 그래서 img 마다 실행당 한 번만 넉넉히 데우고, 프레임은 짧은 타임아웃으로 받는다.
    /// 데우기 결과는 이 실행 안에서만 기억한다 (디스크 기록은 스킬 단위로만).
    private static var warmed: [String: Task<Bool, Never>] = [:]

    private static func resetWarm(_ img: String) {
        cacheLock.lock(); warmed[img] = nil; cacheLock.unlock()
    }

    private static func warmTask(img: String, link: String) -> Task<Bool, Never> {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let t = warmed[img] { return t }
        // 캔버스 안의 노드 하나를 넉넉한 시간으로 한 번 연다. 성공하면 서버 캐시가 데워진다.
        let t = Task<Bool, Never> { await nodeFast(link, timeout: 45) != nil }
        warmed[img] = t
        return t
    }

    static func warmCanvas(forOutlink link: String) async -> Bool {
        guard let seg = link.split(separator: "/").first(where: { $0.hasSuffix(".img") }) else { return true }
        let img = String(seg)
        if await warmTask(img: img, link: link).value { return true }
        // 데우기가 한 번 실패했다고 끝내지 않는다 — 서버가 잠깐 멈춘 것일 수 있으니 한 번 더
        resetWarm(img)
        return await warmTask(img: img, link: link).value
    }

    /// `_Canvas/<img>` 가 서버에서 안 열리는 경우가 있다(5차 버킷 등). 한 번 실패하면 기억해 두고 바로 포기한다.
    private static var badCanvas = Set<String>()
    static func isBadCanvas(_ path: String) -> Bool {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return badCanvas.contains(canvasKey(path))
    }
    /// 이 캔버스 경로가 안 열린다는 건 같은 스킬의 나머지 프레임도 마찬가지라는 뜻이다.
    /// (프로세스 안에서만 기억한다 — 디스크 기록은 스킬 단위로만 한다)
    static func markBadCanvas(_ path: String) {
        cacheLock.lock(); badCanvas.insert(canvasKey(path)); cacheLock.unlock()
    }

    struct Availability: Codable { var unavailable: [String: Double] }   // 스킬 ID → 판정 시각
    private static var badSince: [String: Double] = [:]
    private static var loadedAvailability = false
    static let availabilityURL = Paths.root.appendingPathComponent("image-availability.json")
    /// 일시적 장애였을 수 있으니 하루 지나면 다시 시도한다
    static let availabilityTTL: Double = 86400

    /// 실패를 바로 단정하지 않는다. 넉넉한 시간으로 한 번 더 확인해 정말 못 받는 경우에만 기록한다.
    /// 판정 단위는 **스킬 하나**다 (img 단위로 묶으면 같은 파일에 든 다른 차수 스킬까지 막힌다).
    static func confirmUnavailable(skillId: String, samplePath: String) async {
        // 같은 캔버스를 이번 실행에서 이미 확인했다면 다시 찔러보지 않는다.
        // (디스크에는 스킬 단위로만 남기므로 다른 스킬이 영구히 막히지는 않는다)
        if !isBadCanvas(samplePath) {
            if await frameReachable(samplePath, timeout: 12) { return }   // 일시적 장애였다
            markBadCanvas(samplePath)
        }
        // 대조군: 캔버스와 무관한 가벼운 노드까지 안 되면 서버 전체 문제다. 이 스킬 탓으로 기록하지 않는다.
        if await nodeFast("String/Skill.img/\(skillId)/name", timeout: 8) == nil { return }
        let snapshot = recordBad(skillId)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? Paths.ensureDirectories()
        try? Paths.atomicWrite(try enc.encode(Availability(unavailable: snapshot)), to: availabilityURL)
    }

    private static func recordBad(_ id: String) -> [String: Double] {
        cacheLock.lock(); defer { cacheLock.unlock() }
        badSkills.insert(id); badSince[id] = Date().timeIntervalSince1970
        return badSince
    }

    private static var badSkills = Set<String>()

    static func markAvailable(skillId: String) {
        let snapshot: [String: Double]? = {
            cacheLock.lock(); defer { cacheLock.unlock() }
            guard badSkills.remove(skillId) != nil else { return nil }
            badSince[skillId] = nil
            return badSince
        }()
        guard let snapshot else { return }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? Paths.atomicWrite(try enc.encode(Availability(unavailable: snapshot)), to: availabilityURL)
    }

    /// 같은 스킬의 다른 ID(강화 단계)도 같은 파일이라 함께 기록한다 — 목록 표시와 다음 실행 건너뛰기용
    static func markUnavailable(skillIds: [String]) {
        let snapshot: [String: Double] = {
            cacheLock.lock(); defer { cacheLock.unlock() }
            let now = Date().timeIntervalSince1970
            for id in skillIds { badSkills.insert(id); badSince[id] = now }
            return badSince
        }()
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? Paths.ensureDirectories()
        try? Paths.atomicWrite(try enc.encode(Availability(unavailable: snapshot)), to: availabilityURL)
    }

    static func isBadSkill(_ skillId: String) -> Bool {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return badSkills.contains(skillId)
    }

    /// 프레임 이미지를 실제로 받을 수 있는지 (직접 값 또는 _outlink 경유)
    /// 특정 버전에서 이 프레임의 진짜 이미지(1×1 자리표시자가 아닌)가 내려오는가
    static func realFrame(_ path: String, version v: String, timeout: TimeInterval) async -> Bool {
        func real(_ n: [String: Any]?) -> Bool {
            guard let n, let b64 = n["value"] as? String, let d = Data(base64Encoded: b64), d.count > 24 else { return false }
            let w = Int(d[16]) << 24 | Int(d[17]) << 16 | Int(d[18]) << 8 | Int(d[19])
            return w > 1
        }
        guard let n = await nodeFast(path, timeout: timeout, version: v) else { return false }
        if real(n) { return true }
        guard let link = (await nodeFast("\(path)/_outlink", timeout: timeout, version: v))?["value"] as? String else { return false }
        return real(await nodeFast(link, timeout: timeout, version: v))
    }

    static func frameReachable(_ path: String, timeout: TimeInterval) async -> Bool {
        guard let n = await nodeFast(path, timeout: timeout) else { return false }
        if let b64 = n["value"] as? String, let d = Data(base64Encoded: b64), d.count > 24 {
            let w = Int(d[16]) << 24 | Int(d[17]) << 16 | Int(d[18]) << 8 | Int(d[19])
            if w > 1 { return true }
        }
        guard let link = (await nodeFast("\(path)/_outlink", timeout: timeout))?["value"] as? String,
              let t = await nodeFast(link, timeout: timeout),
              let b = (t["value"] as? String).flatMap({ Data(base64Encoded: $0) }), b.count > 24 else { return false }
        return true
    }

    static func loadAvailability() {
        cacheLock.lock(); let already = loadedAvailability; cacheLock.unlock()
        if already { return }
        loadVersionOverrides()
        var loaded: [String: Double] = [:]
        if let d = try? Data(contentsOf: availabilityURL),
           let a = try? JSONDecoder().decode(Availability.self, from: d) {
            let now = Date().timeIntervalSince1970
            loaded = a.unavailable.filter { now - $0.value < availabilityTTL }   // 오래된 판정은 버린다
        }
        cacheLock.lock()
        badSince = loaded; badSkills.formUnion(loaded.keys); loadedAvailability = true
        cacheLock.unlock()
    }

    private static func canvasKey(_ path: String) -> String {
        path.split(separator: "/").prefix(2).joined(separator: "/")   // "Skill/_Canvas" 다음 img 까지
            + "/" + (path.split(separator: "/").dropFirst(2).first.map(String.init) ?? "")
    }

    // MARK: - 스킬 이름

    private static var nameCache: [String: String] = [:]
    private static let cacheLock = NSLock()

    private static func cached(_ id: String) -> String? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return nameCache[id]
    }
    private static func store(_ id: String, _ name: String) {
        cacheLock.lock(); nameCache[id] = name; cacheLock.unlock()
    }

    static func skillName(_ id: String) async -> String? {
        if let n = cached(id) { return n }
        guard let v = (try? await value("String/Skill.img/\(id)/name")) as? String, !v.isEmpty else { return nil }
        store(id, v)
        return v
    }

    static func skillNames(_ ids: [String]) async -> [String: String] {
        var out: [String: String] = [:]
        await withTaskGroup(of: (String, String?).self) { group in
            var it = ids.makeIterator()
            func next() { if let i = it.next() { group.addTask { (i, await skillName(i)) } } }
            for _ in 0..<6 { next() }
            for await (id, n) in group {
                if let n { out[id] = n }
                next()
            }
        }
        return out
    }

    // MARK: - 직업 코드

    /// 4차 직업 img 후보. 4차 직업 코드는 끝자리가 2(또는 에반 8)이고 3~5자리다.
    static func jobImageCandidates() async throws -> [String] {
        let all = try await children("Skill")
        return all.compactMap { c -> String? in
            guard c.hasSuffix(".img") else { return nil }
            let base = String(c.dropLast(4))
            guard base.allSatisfy(\.isNumber), (3...5).contains(base.count),
                  base.hasSuffix("2") || base.hasSuffix("4") || base.hasSuffix("7") || base.hasSuffix("8") else { return nil }
            return base
        }.sorted { ($0.count, $0) < ($1.count, $1) }
    }

    /// 캐릭터의 4차 스킬 이름으로 직업 img 를 찾아낸다 (하드코딩 표 없음).
    /// 결과는 ~/.claude/pet/jobcodes.json 에 직업명별로 캐시.
    static func resolveJobImage(job: String, fourthSkills: [String], progress: (String) -> Void = { _ in }) async throws -> String {
        if let c = JobCodeCache.get(job) { return c }
        let wanted = Set(fourthSkills.filter { !$0.isEmpty })
        guard !wanted.isEmpty else { throw PetError("4차 스킬 정보가 없어 직업을 판별할 수 없습니다") }

        let candidates = try await jobImageCandidates()
        // 겹치는 4차 스킬이 가장 많은 img 가 그 직업이다.
        // (데몬슬레이어·데몬어벤져처럼 계열이 스킬을 공유하므로 "첫 일치" 로는 틀린다)
        func score(_ img: String) async -> Int {
            guard let ids = try? await children("Skill/\(img).img/skill").filter({ $0.allSatisfy(\.isNumber) }), !ids.isEmpty else { return 0 }
            return wanted.intersection(Set((await skillNames(ids)).values)).count
        }
        var best: (img: String, score: Int) = ("", 0)
        var checked = 0
        for chunk in stride(from: 0, to: candidates.count, by: 6).map({ Array(candidates[$0..<min($0 + 6, candidates.count)]) }) {
            checked += chunk.count
            progress("직업 찾는 중 \(checked)/\(candidates.count)")
            await withTaskGroup(of: (String, Int).self) { group in
                for img in chunk { group.addTask { (img, await score(img)) } }
                for await (img, n) in group where n > best.score { best = (img, n) }
            }
        }
        guard best.score >= 3 else { throw PetError("'\(job)' 직업 데이터를 찾지 못했습니다") }
        JobCodeCache.set(job, best.img)
        return best.img
    }

    private enum JobCodeCache {
        static let url = Paths.root.appendingPathComponent("jobcodes.json")
        static func all() -> [String: String] {
            (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))) ?? [:]
        }
        static func get(_ job: String) -> String? { all()[job] }
        static func set(_ job: String, _ code: String) {
            var m = all(); m[job] = code
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? Paths.ensureDirectories()
            try? Paths.atomicWrite(try enc.encode(m), to: url)
        }
    }

    // MARK: - 직업 스킬 목록

    /// 5차 스킬은 직업 구분 없이 40000~40005.img 에 섞여 있어, 캐릭터가 실제로 가진 이름으로 골라낸다.
    static let fifthJobImages = ["40000", "40001", "40002", "40003", "40004", "40005"]

    struct Skill {
        let id: String
        let name: String
        let img: String
        var tier: String
        var tierOrder: Int
    }

    /// 하위 차수 img: 422 → 400(1차), 420(2차), 421(3차)
    static func lowerImages(_ img: String) -> [(img: String, tier: String, order: Int)] {
        guard img.count >= 3, let n = Int(img) else { return [] }
        let head = String(img.dropLast(2))          // "4" 또는 "21"
        let branch = String(img.dropLast(1))        // "42"
        return [(head + "00", "1차", 1), (branch + "0", "2차", 2), (branch + "1", "3차", 3)]
            .filter { Int($0.0) != n }
    }

    /// 직업의 전 차수 스킬. `ownedNames` 가 있으면 5차를 그걸로 걸러낸다.
    static func skills(jobImage: String, ownedNames: Set<String>, progress: (String) -> Void = { _ in }) async throws -> [Skill] {
        var out: [Skill] = []
        var seen = Set<String>()

        func collect(_ img: String, _ tier: String, _ order: Int, filter: Set<String>? = nil) async {
            guard let ids = try? await children("Skill/\(img).img/skill").filter({ $0.allSatisfy(\.isNumber) }), !ids.isEmpty else { return }
            let names = await skillNames(ids)
            for (id, name) in names where seen.insert(id).inserted {
                if let filter, !filter.contains(name) { continue }
                out.append(Skill(id: id, name: name, img: img, tier: tier, tierOrder: order))
            }
        }

        // 1~3차 (하위 img)
        for l in lowerImages(jobImage) {
            progress("\(l.tier) 스킬 읽는 중…")
            await collect(l.img, l.tier, l.order)
        }
        // 4차·하이퍼 (본 img) — hyper 노드가 있으면 하이퍼로 분류
        progress("4차 스킬 읽는 중…")
        await collect(jobImage, "4차", 4)
        // 6차: 직업 코드 +2 (422 → 424)
        if let six = JobCodes.sixth(jobImage) {
            progress("6차 스킬 읽는 중…")
            await collect(six, "6차", 7)
        }
        // 5차: 공용 버킷에서 캐릭터가 가진 것만
        if !ownedNames.isEmpty {
            for (i, img) in fifthJobImages.enumerated() {
                progress("5차 스킬 읽는 중 \(i + 1)/\(fifthJobImages.count)")
                await collect(img, "5차", 6, filter: ownedNames)
            }
        }
        // 4차 img 안에는 하이퍼 스킬이 섞여 있다 (노드에 `hyper` 자식이 있음)
        progress("하이퍼 스킬 구분 중…")
        let fourth = out.enumerated().filter { $0.element.tierOrder == 4 }
        var hyperIds = Set<String>()
        await withTaskGroup(of: (String, Bool).self) { group in
            var it = fourth.makeIterator()
            func next() {
                if let (_, s) = it.next() {
                    group.addTask {
                        let ch = (try? await children("Skill/\(s.img).img/skill/\(s.id)")) ?? []
                        return (s.id, ch.contains("hyper"))
                    }
                }
            }
            for _ in 0..<8 { next() }
            for await (id, isHyper) in group {
                if isHyper { hyperIds.insert(id) }
                next()
            }
        }
        for i in out.indices where hyperIds.contains(out[i].id) {
            out[i].tier = "하이퍼"; out[i].tierOrder = 5
        }
        return out
    }

}
