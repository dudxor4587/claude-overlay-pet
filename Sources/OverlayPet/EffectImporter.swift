import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// mapleeditors.com 직업 페이지에서 스킬 프레임(PNG 낱장)을 긁어 이펙트 시트로 조립한다.
/// 페이지는 su-spoiler 섹션("1st Job Advancement", "4th Job Advancement - Shadower", "Hyper Skills"…)으로
/// 차수·전직 경로가 나뉘어 있어 그 구조를 그대로 가져온다.
/// 사용자가 요청할 때 런타임에만 받는다. 에셋 저작권은 원저작자에게 있으며 레포에 넣지 않는다.
enum EffectImporter {
    static let maxFrameSide = 512
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"

    struct Skill {
        let name: String          // 파일명 기반 원본 "Assassinate-Effect"
        let frames: [URL]         // 번호 순
        let tier: String          // "1차" … "6차", "하이퍼", "기본", 기타 섹션명
        let tierOrder: Int
        let path: String?         // 전직 경로 (4차 직업명, 예: "Shadower"). 공용 섹션이면 nil
        let pathIndex: Int        // 같은 이름 경로가 둘일 때 (Arch Mage) 순서

        /// "Assassinate" / "Effect" 처럼 스킬명과 변형으로 나눈다.
        var split: (skill: String, variant: String) {
            let decoded = name.removingPercentEncoding ?? name
            let tokens = decoded.split(separator: "-").map(String.init)
            // 숫자·"Effect2"·"Hit1" 같은 토큰부터 변형으로 본다
            func isVariant(_ t: String) -> Bool {
                let l = t.lowercased()
                if Int(l) != nil { return true }
                let word = l.replacingOccurrences(of: #"\d+$"#, with: "", options: .regularExpression)
                return Self.variantWords.contains(word)
            }
            if let i = tokens.firstIndex(where: isVariant), i > 0 {
                return (tokens[..<i].joined(separator: " "), tokens[i...].joined(separator: " "))
            }
            return (tokens.joined(separator: " "), "")
        }
        var displayName: String {
            let s = split
            let title = SkillNames.korean(s.skill).map { "\($0) (\(s.skill))" } ?? s.skill
            return s.variant.isEmpty ? title : "\(title) · \(s.variant)"
        }
        static let variantWords: Set<String> = ["effect", "hit", "ball", "repeat", "mob", "tile", "tiles", "special", "summon", "screen",
                                                "affect", "die", "stand", "front", "back", "keydown", "prepare", "end", "loop", "start",
                                                "text", "after", "before", "charge", "buff", "cast", "attack", "projectile", "level", "lv"]
    }

    /// 여러 페이지(직업 + 5차 공통)를 합친다. 이름이 겹치면 앞 페이지 것을 쓴다.
    static func listSkills(pages: [URL]) async throws -> [Skill] {
        var out: [Skill] = [], seen = Set<String>()
        var firstError: Error?
        for p in pages {
            do {
                for s in try await listSkills(pageURL: p) where seen.insert(s.name).inserted { out.append(s) }
            } catch { firstError = firstError ?? error }
        }
        if out.isEmpty, let e = firstError { throw e }
        return out
    }

    struct Tier { let name: String; let order: Int; let count: Int }

    /// 스킬 목록에 있는 차수들 (순서대로, 개수 포함)
    static func tiers(_ skills: [Skill]) -> [Tier] {
        Dictionary(grouping: skills, by: { $0.tier })
            .map { Tier(name: $0.key, order: $0.value[0].tierOrder, count: $0.value.count) }
            .sorted { ($0.order, $0.name) < ($1.order, $1.name) }
    }

    /// 기본 선택: 4차·하이퍼·5차 (있는 것만)
    static let defaultTiers: Set<String> = ["4차", "하이퍼", "5차"]

    /// "4,5,hyper,4차" 같은 사용자 입력을 차수 이름으로
    static func parseTiers(_ text: String) -> Set<String> {
        Set(text.split(separator: ",").compactMap { raw -> String? in
            let t = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if t.hasPrefix("hyper") || t == "하이퍼" { return "하이퍼" }
            if t == "beginner" || t == "기본" || t == "0" { return "기본" }
            if let n = Int(t.replacingOccurrences(of: "차", with: "")), (1...6).contains(n) { return "\(n)차" }
            return t.isEmpty ? nil : String(raw)
        })
    }

    /// 직업 경로에 맞는 스킬만: 공용 섹션(path nil) + 해당 경로
    static func filter(_ skills: [Skill], path: String?, pathIndex: Int) -> [Skill] {
        guard let path else { return skills }
        return skills.filter { $0.path == nil || ($0.path == path && $0.pathIndex == pathIndex) }
    }

    static func listSkills(pageURL: URL) async throws -> [Skill] {
        var req = URLRequest(url: pageURL)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("text/html", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let html = String(data: data, encoding: .utf8) else {
            throw PetError("페이지를 불러오지 못했습니다 (\((resp as? HTTPURLResponse)?.statusCode ?? 0))")
        }
        // 섹션 제목과 이미지 URL 을 문서 순서대로 훑는다. HTML 이 minify 돼 있어 속성 따옴표가 없을 수 있다.
        let regex = try NSRegularExpression(
            pattern: #"su-spoiler-title[^>]*>(?:<span[^>]*></span>)?([^<]+)</div>|(https?://[^\s"'<>,]+/resources/[^\s"'<>,]+?\.png)"#)

        struct Section { var title: String; var tier: String; var tierOrder: Int; var path: String?; var pathIndex: Int }
        var section: Section?
        var pathCounts: [String: Int] = [:]
        var currentPath: String?, currentPathIndex = 0
        var groups: [String: (Section, [(Int, URL)])] = [:]
        var order: [String] = []

        for m in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            if let r = Range(m.range(at: 1), in: html) {
                let title = html[r].trimmingCharacters(in: .whitespacesAndNewlines)
                let (tier, tierOrder) = tierOf(title)
                // "2nd Job Advancement - Assassin" 에서 새 경로 시작. 경로 이름은 4차 제목으로 갱신.
                let branch = title.range(of: " - ").map { String(title[$0.upperBound...]).trimmingCharacters(in: .whitespaces) }
                if title.hasPrefix("2nd"), let b = branch {
                    currentPath = b; currentPathIndex = 0
                } else if let b = branch {
                    currentPath = b
                    if title.hasPrefix("4th") { pathCounts[b, default: 0] += 1; currentPathIndex = pathCounts[b]! - 1 }
                }
                let path: String? = (title.hasPrefix("1st") || title.hasPrefix("Beginner")) ? nil : currentPath
                section = Section(title: title, tier: tier, tierOrder: tierOrder, path: path, pathIndex: currentPathIndex)
                continue
            }
            guard let r = Range(m.range(at: 2), in: html) else { continue }
            var s = String(html[r])
            s = s.replacingOccurrences(of: #"-\d+x\d+\.png$"#, with: ".png", options: .regularExpression)
            guard let url = URL(string: s) else { continue }
            let file = url.deletingPathExtension().lastPathComponent
            guard let dash = file.lastIndex(of: "-"), let n = Int(file[file.index(after: dash)...]) else { continue }
            let name = String(file[..<dash])
            let sec = section ?? Section(title: "", tier: "기타", tierOrder: 99, path: nil, pathIndex: 0)
            if groups[name] == nil { groups[name] = (sec, []); order.append(name) }
            if !groups[name]!.1.contains(where: { $0.0 == n }) { groups[name]!.1.append((n, url)) }
        }
        // 4차 제목이 나중에 오므로, 2차·3차 섹션의 path 를 같은 그룹의 4차 이름으로 맞춘다.
        // (2nd - Assassin, 3rd - Hermit, 4th - Night Lord → 전부 "Night Lord")
        var lastFourth: [String: String] = [:]   // 2차 이름 → 4차 이름 은 순서로 추적
        var pending: [String] = []
        var resolvedPath: [String: String] = [:]
        for name in order {
            let sec = groups[name]!.0
            guard let p = sec.path else { continue }
            if sec.title.hasPrefix("2nd") || sec.title.hasPrefix("3rd") { pending.append(name); resolvedPath[name] = p }
            else if sec.title.hasPrefix("4th") {
                for q in pending { lastFourth[q] = p }
                pending.removeAll()
            }
        }
        return order.compactMap { name in
            let (sec, list) = groups[name]!
            guard list.count >= 2 else { return nil }
            let path = sec.path.map { lastFourth[name] ?? $0 }
            return Skill(name: name, frames: list.sorted { $0.0 < $1.0 }.map(\.1),
                         tier: sec.tier, tierOrder: sec.tierOrder, path: path, pathIndex: sec.pathIndex)
        }
    }

    static func tierOf(_ title: String) -> (String, Int) {
        let t = title.lowercased()
        if t.hasPrefix("beginner") { return ("기본", 0) }
        if t.hasPrefix("1st") { return ("1차", 1) }
        if t.hasPrefix("2nd") { return ("2차", 2) }
        if t.hasPrefix("3rd") { return ("3차", 3) }
        if t.hasPrefix("4th") { return ("4차", 4) }
        if t.hasPrefix("hyper") { return ("하이퍼", 5) }
        if t.hasPrefix("5th") { return ("5차", 6) }
        if t.hasPrefix("6th") { return ("6차", 7) }
        return (title, 50)
    }

    /// 프레임을 내려받아 ~/.claude/pet/effects/<slug>/ 에 effect.json + sheet.png 로 설치. 반환: 이펙트 이름.
    static func install(_ skill: Skill, fps: Double = 12, scale: Double = 1.5,
                        progress: @escaping (String) -> Void) async throws -> String {
        var images = [CGImage?](repeating: nil, count: skill.frames.count)
        var done = 0
        try await withThrowingTaskGroup(of: (Int, CGImage).self) { group in
            var it = skill.frames.enumerated().makeIterator()
            for _ in 0..<4 { if let (i, u) = it.next() { group.addTask { (i, try await download(u)) } } }
            for try await (i, img) in group {
                images[i] = img; done += 1
                progress("\(skill.displayName) \(done)/\(skill.frames.count)")
                if let (j, u) = it.next() { group.addTask { (j, try await download(u)) } }
            }
        }
        let frames = images.compactMap { $0 }
        guard !frames.isEmpty else { throw PetError("프레임이 없습니다") }

        // 프레임 크기가 제각각이라 최대 크기 셀에 하단 중앙 정렬. 너무 크면(6차 오리진 등) 줄여서 저장.
        let rawW = frames.map(\.width).max()!, rawH = frames.map(\.height).max()!
        let shrink = min(1.0, Double(maxFrameSide) / Double(max(rawW, rawH)))
        let fw = Int(Double(rawW) * shrink), fh = Int(Double(rawH) * shrink)
        let cols = min(frames.count, max(1, Int(ceil(sqrt(Double(frames.count))))))
        let rows = Int(ceil(Double(frames.count) / Double(cols)))
        guard let ctx = CGContext(data: nil, width: fw * cols, height: fh * rows, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw PetError("비트맵 생성 실패") }
        ctx.interpolationQuality = shrink < 1 ? .high : .none
        for (i, img) in frames.enumerated() {
            let c = i % cols, r = i / cols
            let w = CGFloat(img.width) * shrink, h = CGFloat(img.height) * shrink
            let x = CGFloat(c * fw) + (CGFloat(fw) - w) / 2
            let y = CGFloat((rows - 1 - r) * fh)   // CG 는 아래가 원점: 셀 바닥에 붙임
            ctx.draw(img, in: CGRect(x: x, y: y, width: w, height: h))
        }
        guard let sheet = ctx.makeImage() else { throw PetError("시트 생성 실패") }

        let name = SheetBuilder.slug(skill.name.removingPercentEncoding ?? skill.name)
        let dir = Paths.effectDirectory(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let png = dir.appendingPathComponent("sheet.png")
        guard let dst = CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw PetError("PNG 저장 실패") }
        CGImageDestinationAddImage(dst, sheet, nil)
        guard CGImageDestinationFinalize(dst) else { throw PetError("PNG 저장 실패") }

        var m = EffectManifest(frameWidth: fw, frameHeight: fh, frames: frames.count, columns: cols)
        m.fps = fps; m.loop = false; m.anchor = "bottom"; m.scale = scale / shrink   // 줄인 만큼 표시 배율로 보정
        let sp = skill.split
        m.skill = sp.skill; m.variant = sp.variant; m.tier = skill.tier; m.tierOrder = skill.tierOrder; m.path = skill.path
        m.koreanName = SkillNames.korean(sp.skill)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(m).write(to: dir.appendingPathComponent("effect.json"))
        return name
    }

    /// 여러 스킬 설치. 이미 있는 건 건너뛴다. 반환: 설치된 이펙트 이름들.
    static func installAll(_ skills: [Skill], progress: @escaping (String) -> Void) async -> [String] {
        var names: [String] = []
        var done = 0, failed = 0
        await withTaskGroup(of: String?.self) { group in
            var it = skills.makeIterator()
            func next() {
                if let s = it.next() {
                    group.addTask {
                        let name = SheetBuilder.slug(s.name.removingPercentEncoding ?? s.name)
                        if FileManager.default.fileExists(atPath: Paths.effectDirectory(name).appendingPathComponent("effect.json").path) { return name }
                        return try? await install(s) { _ in }
                    }
                }
            }
            for _ in 0..<3 { next() }
            for await r in group {
                done += 1
                if let r { names.append(r) } else { failed += 1 }
                progress("스킬 \(done)/\(skills.count)" + (failed > 0 ? " (실패 \(failed))" : ""))
                next()
            }
        }
        return names.sorted()
    }

    private static func download(_ url: URL) async throws -> CGImage {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        var last: Error?
        for _ in 0..<3 {
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw PetError("프레임 다운로드 실패 \(url.lastPathComponent)") }
                guard let src = CGImageSourceCreateWithData(data as CFData, nil),
                      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw PetError("프레임 디코드 실패") }
                return img
            } catch { last = error }
        }
        throw last!
    }
}
