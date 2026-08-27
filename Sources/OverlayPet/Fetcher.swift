import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - 넥슨 Open API

struct NexonCharacter {
    let ocid: String
    let name: String
    let world: String
    let job: String
    let level: Int
    /// 쿼리 없는 외형 이미지 URL
    let imageURL: URL
}

enum NexonClient {
    static let base = URL(string: "https://open.api.nexon.com")!
    static let lookPrefix = "/static/maplestory/character/look/"

    static func fetchCharacter(name: String, apiKey: String) async throws -> NexonCharacter {
        var idURL = URLComponents(url: base.appendingPathComponent("maplestory/v1/id"), resolvingAgainstBaseURL: false)!
        idURL.queryItems = [URLQueryItem(name: "character_name", value: name)]
        let id = try await getJSON(idURL.url!, apiKey: apiKey)
        guard let ocid = id["ocid"] as? String, !ocid.isEmpty else { throw PetError("캐릭터를 찾을 수 없습니다: \(name)") }

        var basicURL = URLComponents(url: base.appendingPathComponent("maplestory/v1/character/basic"), resolvingAgainstBaseURL: false)!
        basicURL.queryItems = [URLQueryItem(name: "ocid", value: ocid)]
        let basic = try await getJSON(basicURL.url!, apiKey: apiKey)
        guard let img = basic["character_image"] as? String,
              var comps = URLComponents(string: img),
              comps.scheme == "https", comps.host == "open.api.nexon.com",
              comps.path.hasPrefix(lookPrefix), comps.path.count > lookPrefix.count
        else { throw PetError("캐릭터 이미지 URL 이 예상과 다릅니다") }
        comps.query = nil; comps.fragment = nil
        return NexonCharacter(
            ocid: ocid,
            name: basic["character_name"] as? String ?? name,
            world: basic["world_name"] as? String ?? "",
            job: basic["character_class"] as? String ?? "",
            level: basic["character_level"] as? Int ?? 0,
            imageURL: comps.url!)
    }

    static func frameURL(_ base: URL, action: String, emotion: String, weapon: Bool) -> URL {
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        c.queryItems = [
            .init(name: "action", value: action), .init(name: "emotion", value: emotion),
            .init(name: "wmotion", value: weapon ? "W00" : "W04"),
            .init(name: "width", value: "400"), .init(name: "height", value: "400"),
            .init(name: "x", value: "200"), .init(name: "y", value: "280"),
        ]
        return c.url!
    }

    static func getJSON(_ url: URL, apiKey: String) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.setValue(apiKey, forHTTPHeaderField: "x-nxopen-api-key")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any]
            let msg = body?["message"] as? String ?? ""
            switch status {
            case 400, 404: throw PetError("캐릭터를 찾을 수 없습니다 (\(status)) \(msg)")
            case 403: throw PetError("API 키가 올바르지 않습니다 (403) \(msg)")
            case 429: throw PetError("요청이 너무 많습니다. 잠시 후 다시 시도 (429)")
            default: throw PetError("넥슨 API 오류 (\(status)) \(msg)")
            }
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PetError("JSON 파싱 실패") }
        return obj
    }

    static func download(_ url: URL) async throws -> CGImage {
        var last: Error?
        for _ in 0..<3 {
            do {
                let (data, resp) = try await URLSession.shared.data(from: url)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw PetError("프레임 다운로드 실패 \(url)") }
                guard let src = CGImageSourceCreateWithData(data as CFData, nil),
                      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw PetError("프레임 디코드 실패") }
                return img
            } catch { last = error }
        }
        throw last!
    }
}

// MARK: - 프레임 계획 (maple-hatch-pet 의 9행 레이아웃과 동일)

struct RowPlan {
    var action: String      // A00 ~ A41
    var emotion: String     // E00 ~ E24
    var frames: Int         // 목표 셀 수 (≤ 8)
    var flip: Bool = false
}

enum FramePlan {
    /// 액션 코드 → 마지막 하위 프레임 번호 (넥슨 공지 2715682 기준)
    static let actionLastFrame: [String: Int] = [
        "A00": 2, "A01": 2, "A02": 3, "A03": 3, "A04": 0, "A05": 1, "A06": 0, "A07": 0, "A08": 1, "A09": 1,
        "A10": 2, "A11": 2, "A12": 1, "A13": 2, "A14": 2, "A15": 2, "A16": 3, "A17": 2, "A18": 2, "A19": 3,
        "A20": 2, "A21": 2, "A22": 2, "A23": 3, "A24": 1, "A25": 1, "A26": 2, "A27": 2, "A28": 2, "A29": 3,
        "A30": 2, "A31": 4, "A32": 2, "A33": 0, "A34": 3, "A35": 2, "A36": 0, "A37": 1, "A38": 1, "A39": 1,
        "A40": 1, "A41": 0,
    ]

    /// 행 순서: 서기 / 걷기(오른쪽, 좌우반전) / 걷기(왼쪽) / 손흔들기 / 점프 / 유령 / 대기 / 공격 / 엎드리기
    static let defaultRows: [RowPlan] = [
        RowPlan(action: "A01", emotion: "E00", frames: 6),
        RowPlan(action: "A02", emotion: "E01", frames: 8, flip: true),
        RowPlan(action: "A02", emotion: "E01", frames: 8),
        RowPlan(action: "A00", emotion: "E02", frames: 4),
        RowPlan(action: "A06", emotion: "E10", frames: 5),
        RowPlan(action: "A34", emotion: "E03", frames: 8),
        RowPlan(action: "A11", emotion: "E00", frames: 6),
        RowPlan(action: "A14", emotion: "E15", frames: 6),
        RowPlan(action: "A12", emotion: "E09", frames: 6),
    ]

    static func subFrames(_ row: RowPlan) throws -> [(action: String, emotion: String)] {
        guard let last = actionLastFrame[row.action] else { throw PetError("알 수 없는 액션 코드 \(row.action)") }
        return (0..<row.frames).map { ("\(row.action).\($0 % (last + 1))", "\(row.emotion).0") }
    }
}

// MARK: - 시트 조립

enum SheetBuilder {
    static let cellW = SpriteSheet.defaultFrameWidth
    static let cellH = SpriteSheet.defaultFrameHeight
    static let columns = SpriteSheet.defaultColumns
    static let normalizedWidth: CGFloat = 576
    static let anchorRatio = CGPoint(x: 0.5, y: 0.7)   // 소스 이미지 기준 발 위치
    static let cellAnchor = CGPoint(x: 96, y: 188)       // 셀 안에서 발이 놓일 자리 (좌상단 원점)

    /// 캐릭터명 → 프레임 수집 → pets/<id>/ 설치. 진행 상황은 progress 로 알려준다.
    static func build(characterName: String, apiKey: String, weapon: Bool, rows: [RowPlan] = FramePlan.defaultRows,
                      progress: @escaping (String) -> Void) async throws -> String {
        progress("캐릭터 조회 중…")
        let ch = try await NexonClient.fetchCharacter(name: characterName, apiKey: apiKey)

        // 같은 URL 은 한 번만 받는다.
        var urls: [URL] = []
        var seen = Set<URL>()
        let plans = try rows.map { try FramePlan.subFrames($0) }
        for p in plans { for f in p {
            let u = NexonClient.frameURL(ch.imageURL, action: f.action, emotion: f.emotion, weapon: weapon)
            if seen.insert(u).inserted { urls.append(u) }
        } }

        var images: [URL: CGImage] = [:]
        var done = 0
        try await withThrowingTaskGroup(of: (URL, CGImage).self) { group in
            var it = urls.makeIterator()
            for _ in 0..<4 { if let u = it.next() { group.addTask { (u, try await NexonClient.download(u)) } } }
            for try await (u, img) in group {
                images[u] = img; done += 1
                progress("프레임 \(done)/\(urls.count)")
                if let n = it.next() { group.addTask { (n, try await NexonClient.download(n)) } }
            }
        }

        progress("시트 조립 중…")
        let sheetW = cellW * columns, sheetH = cellH * rows.count
        guard let ctx = CGContext(data: nil, width: sheetW, height: sheetH, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw PetError("비트맵 생성 실패") }
        ctx.interpolationQuality = .none

        for (r, plan) in plans.enumerated() {
            for (c, f) in plan.enumerated() {
                let u = NexonClient.frameURL(ch.imageURL, action: f.action, emotion: f.emotion, weapon: weapon)
                guard let img = images[u] else { throw PetError("프레임 누락") }
                let scale = normalizedWidth / CGFloat(img.width)
                let w = CGFloat(img.width) * scale, h = CGFloat(img.height) * scale
                // 셀 좌상단 기준 배치 위치
                let left = cellAnchor.x - CGFloat(img.width) * anchorRatio.x * scale
                let top = cellAnchor.y - CGFloat(img.height) * anchorRatio.y * scale
                let cellX = CGFloat(c * cellW), cellYTop = CGFloat(r * cellH)
                ctx.saveGState()
                ctx.clip(to: CGRect(x: cellX, y: CGFloat(sheetH) - cellYTop - CGFloat(cellH), width: CGFloat(cellW), height: CGFloat(cellH)))
                // CG 는 원점이 좌하단
                var dest = CGRect(x: cellX + left, y: CGFloat(sheetH) - cellYTop - top - h, width: w, height: h)
                if rows[r].flip {
                    ctx.translateBy(x: cellX + CGFloat(cellW), y: 0); ctx.scaleBy(x: -1, y: 1)
                    dest.origin.x = left
                }
                ctx.draw(img, in: dest)
                ctx.restoreGState()
            }
        }
        guard let sheet = ctx.makeImage() else { throw PetError("시트 이미지 생성 실패") }

        let id = slug(ch.name)
        let dir = Paths.petDirectory(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let png = dir.appendingPathComponent("spritesheet.png")
        guard let dst = CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw PetError("PNG 저장 실패") }
        CGImageDestinationAddImage(dst, sheet, nil)
        guard CGImageDestinationFinalize(dst) else { throw PetError("PNG 저장 실패") }

        let manifest = PetManifest(
            id: id, displayName: ch.name,
            description: "\(ch.world) · \(ch.job) · Lv.\(ch.level)",
            spriteVersionNumber: 1, spritesheetPath: "spritesheet.png",
            frameWidth: cellW, frameHeight: cellH, columns: columns, rows: rows.count,
            frameCounts: rows.map(\.frames), job: ch.job, ocid: ch.ocid)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(manifest).write(to: dir.appendingPathComponent("pet.json"))
        progress("설치 완료: \(id)")
        return id
    }

    static func slug(_ name: String) -> String {
        let s = name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "-")).isEmpty ? "pet" : s
    }
}

enum Pets {
    static func installed() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: Paths.pets.path)) ?? [])
            .filter { FileManager.default.fileExists(atPath: Paths.petDirectory($0).appendingPathComponent("pet.json").path) }
            .sorted()
    }
}
