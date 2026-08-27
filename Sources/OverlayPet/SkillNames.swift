import Foundation
import CoreGraphics
import ImageIO

/// 스킬 영문(GMS) → 한글(KMS) 이름. 캐릭터를 가져올 때 본인 캐릭터 기준으로 만들어 pets/<id>/skill-names.json 에 둔다.
///   넥슨 API: 캐릭터 스킬(한글 이름 + 32x32 아이콘)  ↔  maplestorywiki.net 직업 페이지: 영문 이름 + 같은 아이콘
///   아이콘이 거의 같고(리비전 차 허용) 2등과 확실히 구분될 때만 짝을 지으므로 틀린 이름이 붙지 않는다. 못 맞춘 스킬은 영문 그대로.
enum SkillNames {
    private(set) static var current: [String: String] = [:]   // normalized en → ko

    static func fileURL(petId: String) -> URL { Paths.petDirectory(petId).appendingPathComponent("skill-names.json") }

    static func load(petId: String?) {
        current = [:]
        guard let petId, let data = try? Data(contentsOf: fileURL(petId: petId)),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        for (en, ko) in map { current[normalize(en)] = ko }
    }

    static func korean(_ english: String) -> String? {
        let key = normalize(english)
        if let ko = current[key] { return ko }
        // "HEXA Assassinate" → "Assassinate"
        if key.hasPrefix("hexa "), let ko = current[String(key.dropFirst(5))] { return ko + " VI" }
        return nil
    }

    static func normalize(_ s: String) -> String {
        var t = s.lowercased().replacingOccurrences(of: "’", with: "'")
        t = t.replacingOccurrences(of: "[^a-z0-9가-힣]+", with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - 만들기

    static func hasTable(petId: String) -> Bool { FileManager.default.fileExists(atPath: fileURL(petId: petId).path) }

    /// 펫 매니페스트(직업·ocid)로 표를 만든다. ocid 가 없으면 캐릭터명으로 조회.
    static func resolve(petId: String, apiKey: String, progress: @escaping (String) -> Void) async throws -> (matched: Int, total: Int) {
        let m = try PetManifest.load(petId: petId)
        guard let job = m.jobName, let wiki = JobPages.entry(forJob: job)?.wiki else { throw PetError("'\(m.jobName ?? "?")' 직업은 한글 스킬명 매칭을 지원하지 않습니다") }
        var ocid = m.ocid
        if ocid == nil {
            var c = URLComponents(string: "https://open.api.nexon.com/maplestory/v1/id")!
            c.queryItems = [.init(name: "character_name", value: m.displayName)]
            ocid = (try await NexonClient.getJSON(c.url!, apiKey: apiKey))["ocid"] as? String
        }
        guard let ocid else { throw PetError("캐릭터 ocid 를 찾지 못했습니다") }
        return try await build(petId: petId, ocid: ocid, apiKey: apiKey, wikiJob: wiki, progress: progress)
    }

    static let grades = ["0", "1", "2", "3", "4", "hyperpassive", "hyperactive", "5", "6"]

    /// 캐릭터 스킬과 위키 아이콘을 맞춰 표를 만들고 저장한다. 반환: 짝지은 개수 / 위키 스킬 수
    static func build(petId: String, ocid: String, apiKey: String, wikiJob: String,
                      progress: @escaping (String) -> Void) async throws -> (matched: Int, total: Int) {
        // 1. 본인 캐릭터 스킬 (한글 이름 + 아이콘)
        var kr: [(name: String, px: [UInt8])] = []
        var seen = Set<String>()
        for (i, g) in grades.enumerated() {
            progress("스킬 이름 읽는 중 \(i + 1)/\(grades.count)")
            var c = URLComponents(string: "https://open.api.nexon.com/maplestory/v1/character/skill")!
            c.queryItems = [.init(name: "ocid", value: ocid), .init(name: "character_skill_grade", value: g)]
            // 넥슨이 초당 제한에 걸리면 조용히 실패하므로 재시도
            var list: [[String: Any]]?
            for attempt in 0..<4 {
                if let json = try? await NexonClient.getJSON(c.url!, apiKey: apiKey) { list = json["character_skill"] as? [[String: Any]]; break }
                try? await Task.sleep(nanoseconds: UInt64(700_000_000 * (attempt + 1)))
            }
            guard let list else { continue }
            for s in list {
                guard let n = s["skill_name"] as? String, let icon = s["skill_icon"] as? String, let u = URL(string: icon),
                      seen.insert(n).inserted, let px = try? await iconPixels(u) else { continue }
                kr.append((n, px))
            }
            try? await Task.sleep(nanoseconds: 300_000_000)   // 초당 호출 제한
        }
        guard !kr.isEmpty else { throw PetError("캐릭터 스킬을 읽지 못했습니다") }

        // 2. 위키 아이콘 (영문 이름)
        progress("위키 스킬 목록 읽는 중…")
        let page = URL(string: "https://maplestorywiki.net/w/" + wikiJob.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)! + "/Skills")!
        var req = URLRequest(url: page)
        req.setValue(EffectImporter.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let html = String(data: data, encoding: .utf8) else {
            throw PetError("위키 페이지를 읽지 못했습니다: \(wikiJob)")
        }
        let re = try NSRegularExpression(pattern: #"src="(https://media\.maplestorywiki\.net/yetidb/Skill_([^"]+?)\.png)""#)
        var wiki: [(name: String, url: URL)] = []
        var wseen = Set<String>()
        for m in re.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let ur = Range(m.range(at: 1), in: html), let nr = Range(m.range(at: 2), in: html), let u = URL(string: String(html[ur])) else { continue }
            var n = (String(html[nr]).removingPercentEncoding ?? "").replacingOccurrences(of: "_", with: " ")
            n = n.replacingOccurrences(of: #"\s*\(\d+\)$"#, with: "", options: .regularExpression)
            if n.range(of: #"^\d(st|nd|rd|th) Job$"#, options: .regularExpression) != nil { continue }
            if wseen.insert(n).inserted { wiki.append((n, u)) }
        }

        // 3. 아이콘 매칭 (완전 일치만)
        var map: [String: String] = [:]
        for (i, w) in wiki.enumerated() {
            if i % 10 == 0 { progress("스킬 이름 맞추는 중 \(i)/\(wiki.count)") }
            guard let px = try? await iconPixels(w.url) else { continue }
            // 같은 스킬도 리비전에 따라 몇 픽셀 다를 수 있다(평균 차 ~5). 다른 스킬은 보통 30 이상.
            // 가장 가까운 것이 충분히 가깝고 2등과 확실히 벌어질 때만 짝을 짓는다.
            let ranked = kr.map { ($0.name, meanDiff($0.px, px)) }.sorted { $0.1 < $1.1 }
            if let best = ranked.first, best.1 < 12, ranked.count < 2 || ranked[1].1 - best.1 > 10 { map[w.name] = best.0 }
        }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(map).write(to: fileURL(petId: petId))
        load(petId: petId)
        return (map.count, wiki.count)
    }

    private static func iconPixels(_ url: URL) async throws -> [UInt8] {
        var req = URLRequest(url: url)
        req.setValue(EffectImporter.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw PetError("아이콘 디코드 실패") }
        var buf = [UInt8](repeating: 0, count: 32 * 32 * 4)
        guard let ctx = CGContext(data: &buf, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw PetError("비트맵 실패") }
        ctx.interpolationQuality = .none
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: 32, height: 32))
        return buf
    }

    private static func meanDiff(_ a: [UInt8], _ b: [UInt8]) -> Double {
        var s = 0; for i in 0..<a.count { s += abs(Int(a[i]) - Int(b[i])) }
        return Double(s) / Double(a.count)
    }
}
