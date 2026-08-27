import Foundation
import CoreGraphics
import ImageIO

/// pets/<id>/pet.json — maple-hatch-pet 의 매니페스트와 호환.
struct PetManifest: Codable {
    var id: String
    var displayName: String
    var description: String
    var spriteVersionNumber: Int
    var spritesheetPath: String
    /// 선택: 셀 크기·행별 프레임 수. 없으면 192x208, 8x9 + 알파로 자동 감지.
    var frameWidth: Int?
    var frameHeight: Int?
    var columns: Int?
    var rows: Int?
    var frameCounts: [Int]?
    /// 넥슨 직업명 (이펙트 페이지 자동 선택용). 없으면 description "월드 · 직업 · Lv" 에서 추출.
    var job: String?
    var ocid: String?

    static func load(petId: String) throws -> PetManifest {
        try JSONDecoder().decode(PetManifest.self, from: Data(contentsOf: Paths.petDirectory(petId).appendingPathComponent("pet.json")))
    }

    var jobName: String? {
        if let job, !job.isEmpty { return job }
        let parts = description.components(separatedBy: " · ")
        return parts.count >= 3 ? parts[1] : nil
    }
}

struct SpriteSheet {
    static let defaultFrameWidth = 192
    static let defaultFrameHeight = 208
    static let defaultColumns = 8
    static let defaultRows = 9
    static let defaultFrameCounts = [6, 8, 8, 4, 5, 8, 6, 6, 6]

    let image: CGImage
    let frameWidth: Int
    let frameHeight: Int
    let columns: Int
    let rows: Int
    let frameCounts: [Int]

    /// 행 r, 열 c 의 셀 (단위 좌표, CALayer.contentsRect 용. 원점 좌상단)
    func contentsRect(row: Int, column: Int) -> CGRect {
        CGRect(x: CGFloat(column * frameWidth) / CGFloat(image.width),
               y: CGFloat(row * frameHeight) / CGFloat(image.height),
               width: CGFloat(frameWidth) / CGFloat(image.width),
               height: CGFloat(frameHeight) / CGFloat(image.height))
    }

    static func load(petId: String) throws -> (PetManifest, SpriteSheet) {
        let dir = Paths.petDirectory(petId)
        let manifest = try JSONDecoder().decode(PetManifest.self, from: Data(contentsOf: dir.appendingPathComponent("pet.json")))
        let png = dir.appendingPathComponent(manifest.spritesheetPath)
        guard let image = loadImage(png) else {
            throw PetError("스프라이트 시트를 읽을 수 없음: \(png.path)")
        }
        let fw = manifest.frameWidth ?? defaultFrameWidth
        let fh = manifest.frameHeight ?? defaultFrameHeight
        let cols = manifest.columns ?? max(1, image.width / fw)
        let rows = manifest.rows ?? max(1, image.height / fh)
        let counts = manifest.frameCounts ?? detectFrameCounts(image, fw: fw, fh: fh, cols: cols, rows: rows)
        return (manifest, SpriteSheet(image: image, frameWidth: fw, frameHeight: fh, columns: cols, rows: rows, frameCounts: counts))
    }

    static func loadImage(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// 사용하지 않는 셀은 완전 투명하다는 규칙을 이용해 행별 프레임 수를 센다.
    static func detectFrameCounts(_ image: CGImage, fw: Int, fh: Int, cols: Int, rows: Int) -> [Int] {
        guard let alpha = Raster.alphaMask(image) else { return Array(repeating: cols, count: rows) }
        var counts: [Int] = []
        for r in 0..<rows {
            var n = 0
            for c in 0..<cols {
                var any = false
                let x0 = c * fw, y0 = r * fh
                outer: for y in stride(from: y0, to: min(y0 + fh, image.height), by: 2) {
                    let rowBase = y * image.width
                    for x in stride(from: x0, to: min(x0 + fw, image.width), by: 2) where alpha[rowBase + x] != 0 {
                        any = true; break outer
                    }
                }
                if any { n = c + 1 } else { break }
            }
            counts.append(max(n, 1))
        }
        return counts
    }
}

struct PetError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

enum Raster {
    /// 이미지의 알파 채널만 8bit 로 뽑는다.
    static func alphaMask(_ image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        var buf = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buf
    }
}
