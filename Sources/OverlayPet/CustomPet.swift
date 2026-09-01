import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// 사용자 에셋(GIF·APNG·PNG 낱장들)으로 펫을 만든다.
///
/// 규약: 폴더 안에 상태 이름 파일을 넣는다 — idle.gif 하나면 충분하고,
/// think / bash / edit / done / error / notify / sleep 을 추가할수록 반응이 풍부해진다.
/// 낱장 연번(bash-1.png, bash-2.png…)도 한 애니메이션으로 묶는다.
/// 임포터가 기존 9행 시트 규격으로 구워 pets/<id>/ 에 설치하므로,
/// 재생 쪽(PetWindow·AnimationMap)은 넥슨 펫과 완전히 같은 길을 탄다.
enum CustomPet {
    /// 셀 한 변 상한 — 이보다 큰 프레임은 비율 유지로 줄인다
    static let maxCellSide: CGFloat = 384
    /// 애니메이션당 프레임 상한 — 긴 GIF 는 고르게 표본화한다
    static let maxFrames = 16

    /// 행 → 이 행에 쓸 파일 이름 후보 (앞에 있는 것 우선). 없으면 idle 로 채운다.
    /// SheetRow 레이아웃(서기/걷기/걷기왼쪽/짧은동작/축하/유령/생각/실행/눕기)과 짝.
    static let rowSources: [[String]] = [
        ["idle", "stand"],
        ["edit", "walk"],
        ["edit", "walk"],
        ["notify", "wave"],
        ["done", "start", "celebrate", "jump"],
        ["error", "ghost", "fail"],
        ["think", "prompt", "wait"],
        ["bash", "attack", "run"],
        ["sleep", "end", "lie"],
    ]

    /// source 가 파일이면 그 애니메이션 하나(idle)로, 폴더면 상태 이름 규약으로 읽어 설치한다.
    static func build(source: URL, name: String, progress: (String) -> Void = { _ in }) throws -> String {
        progress("에셋 읽는 중…")
        return try build(anims: loadAnimations(source), name: name, progress: progress)
    }

    /// 상태 → 프레임들 딕셔너리로 설치한다 (대화상자·수정 경로 공용)
    static func build(anims: [String: [CGImage]], name: String, progress: (String) -> Void = { _ in }) throws -> String {
        guard let idle = anims["idle"] ?? anims.values.first else {
            throw PetError("애니메이션을 찾지 못했어 — idle.gif 나 PNG 를 넣어 줘")
        }

        // 셀 크기: 모든 프레임을 담는 최소 크기 (상한 넘으면 축소)
        let all = anims.values.flatMap { $0 }
        let maxW = CGFloat(all.map(\.width).max() ?? 1), maxH = CGFloat(all.map(\.height).max() ?? 1)
        let shrink = min(1, maxCellSide / max(maxW, maxH))
        let cellW = max(1, Int((maxW * shrink).rounded(.up))), cellH = max(1, Int((maxH * shrink).rounded(.up)))

        // 행 구성: 규약 이름이 있으면 그 애니메이션, 없으면 idle
        let rows: [[CGImage]] = rowSources.map { keys in
            for k in keys { if let a = anims[k] { return a } }
            return idle
        }
        let columns = rows.map(\.count).max() ?? 1

        progress("시트 조립 중…")
        let sheetW = cellW * columns, sheetH = cellH * rows.count
        guard let ctx = CGContext(data: nil, width: sheetW, height: sheetH, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw PetError("비트맵 생성 실패") }
        ctx.interpolationQuality = shrink < 1 ? .high : .none

        for (r, frames) in rows.enumerated() {
            for (c, img) in frames.enumerated() {
                let w = CGFloat(img.width) * shrink, h = CGFloat(img.height) * shrink
                // 발이 흔들리지 않게 아래 중앙 정렬 (CG 원점은 좌하단)
                let x = CGFloat(c * cellW) + (CGFloat(cellW) - w) / 2
                let y = CGFloat(sheetH) - CGFloat((r + 1) * cellH)
                ctx.draw(img, in: CGRect(x: x, y: y, width: w, height: h))
            }
        }
        guard let sheet = ctx.makeImage() else { throw PetError("시트 이미지 생성 실패") }

        let id = SheetBuilder.slug(name)
        let dir = Paths.petDirectory(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let png = dir.appendingPathComponent("spritesheet.png")
        guard let dst = CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw PetError("PNG 저장 실패") }
        CGImageDestinationAddImage(dst, sheet, nil)
        guard CGImageDestinationFinalize(dst) else { throw PetError("PNG 저장 실패") }

        let manifest = PetManifest(
            id: id, displayName: name, description: "커스텀 펫",
            spriteVersionNumber: 1, spritesheetPath: "spritesheet.png",
            frameWidth: cellW, frameHeight: cellH, columns: columns, rows: rows.count,
            frameCounts: rows.map(\.count), job: nil, ocid: nil,
            customStates: anims.keys.sorted(), fetchedAt: nil)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(manifest).write(to: dir.appendingPathComponent("pet.json"))
        progress("설치 완료: \(id)")
        return id
    }

    /// 설치된 커스텀 펫에서 사용자가 넣었던 상태별 프레임을 되꺼낸다 (수정 모드용).
    /// 시트의 행이 곧 애니메이션이므로 customStates 에 기록된 상태의 행만 잘라낸다.
    static func extract(petId: String) throws -> [String: [CGImage]] {
        let (m, sheet) = try SpriteSheet.load(petId: petId)
        var anims: [String: [CGImage]] = [:]
        for state in m.customStates ?? [] {
            guard let r = rowSources.firstIndex(where: { $0.contains(state) }) else { continue }
            let n = r < sheet.frameCounts.count ? sheet.frameCounts[r] : 1
            var fs: [CGImage] = []
            for c in 0..<n {
                let rect = CGRect(x: c * sheet.frameWidth, y: r * sheet.frameHeight,
                                  width: sheet.frameWidth, height: sheet.frameHeight)
                if let f = sheet.image.cropping(to: rect) { fs.append(f) }
            }
            if !fs.isEmpty { anims[state] = fs }
        }
        return anims
    }

    // MARK: 에셋 읽기

    /// 상태 이름 → 프레임들. 단일 파일이면 idle 하나로 취급한다.
    static func loadAnimations(_ source: URL) throws -> [String: [CGImage]] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDir) else {
            throw PetError("경로를 읽을 수 없음: \(source.path)")
        }
        if !isDir.boolValue {
            return ["idle": sample(try frames(of: source))]
        }
        let files = ((try? FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["gif", "png", "apng", "webp", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
        // "bash-1" / "bash_02" / "bash3" → ("bash", 1) — 낱장 연번을 한 애니메이션으로
        var groups: [String: [(Int, URL)]] = [:]
        for f in files {
            let base = f.deletingPathExtension().lastPathComponent
                .precomposedStringWithCanonicalMapping.lowercased()
            let digits = base.reversed().prefix(while: \.isNumber).reversed()
            let n = Int(String(digits)) ?? 0
            var key = String(base.dropLast(digits.count))
            while let last = key.last, last == "-" || last == "_" || last == " " { key.removeLast() }
            if key.isEmpty { key = base }
            groups[key, default: []].append((n, f))
        }
        var anims: [String: [CGImage]] = [:]
        for (key, members) in groups {
            var fs: [CGImage] = []
            for (_, url) in members.sorted(by: { $0.0 < $1.0 }) {
                fs.append(contentsOf: try frames(of: url))
            }
            if !fs.isEmpty { anims[key] = sample(fs) }
        }
        return anims
    }

    /// 한 파일의 프레임들 (GIF·APNG 는 전체, 정지 이미지는 한 장)
    static func frames(of url: URL) throws -> [CGImage] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw PetError("이미지를 읽을 수 없음: \(url.lastPathComponent)")
        }
        return (0..<CGImageSourceGetCount(src)).compactMap { CGImageSourceCreateImageAtIndex(src, $0, nil) }
    }

    /// 긴 애니메이션을 고르게 표본화해 상한에 맞춘다
    static func sample(_ fs: [CGImage]) -> [CGImage] {
        guard fs.count > maxFrames else { return fs }
        return (0..<maxFrames).map { fs[$0 * fs.count / maxFrames] }
    }
}
