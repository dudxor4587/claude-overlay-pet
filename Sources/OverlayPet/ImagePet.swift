import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import Vision

/// 정지 이미지 한 장으로 상태별 애니메이션을 만든다.
///
/// 문어(DefaultPet)와 **같은 포즈 정의**(`DefaultPet.pose`)를 쓴다. 다른 점은 몸을 그리는 대신
/// 이미지를 그 포즈대로 변형한다는 것뿐이다 — 눌리고(squash) 기울고(lean) 뜨고(dy) 흐려진다(alpha).
/// 그래서 문어와 이미지 펫의 움직임이 어긋나지 않는다.
///
/// 사진은 배경이 있어 그대로 쓰면 네모가 튀어다닌다. 알파가 없으면 Vision 으로 피사체만 떼어낸다
/// (macOS 14+, 사진 앱의 "피사체 복사"와 같은 기능). 13 이거나 피사체를 못 찾으면 알려주고 멈춘다.
enum ImagePet {
    /// 만들 셀 크기. 위쪽은 점프·둥둥 뜨는 여유로 비워 둔다.
    static let cell = CGSize(width: 320, height: 340)
    /// 셀 바닥에서 발까지
    static let baselineY: CGFloat = 24
    /// 피사체가 차지할 세로 비율 (나머지는 움직임 여유)
    static let bodyRatio: CGFloat = 0.62

    /// 행 → 상태 키. CustomPet.rowSources 의 대표 이름과 짝을 맞춘다.
    static var stateForRow: [String] { CustomPet.rowSources.map { $0[0] } }

    // MARK: 진입점

    /// 정지 이미지 → 상태별 프레임. CustomPet.build(anims:) 에 그대로 넘길 수 있다.
    static func animations(from source: CGImage, progress: (String) -> Void = { _ in }) throws -> [String: [CGImage]] {
        progress("배경 정리 중…")
        let subject = try prepare(source)

        var out: [String: [CGImage]] = [:]
        for (row, state) in stateForRow.enumerated() {
            // 행 2(왼쪽 걷기)는 어느 상태에도 안 붙어 있어 건너뛴다 — 행 1과 같은 키라 덮어쓰기만 한다
            if row == 2 { continue }
            let n = DefaultPet.counts[row]
            out[state] = (0..<n).map { render(subject, row: row, frame: $0, of: n) }
        }
        return out
    }

    /// 알파가 없으면 누끼를 따고, 있으면 그대로 쓴다. 그 뒤 여백을 잘라낸다.
    static func prepare(_ image: CGImage) throws -> CGImage {
        var img = image
        if !hasTransparency(img) {
            guard #available(macOS 14.0, *) else {
                throw PetError("배경이 있는 사진은 macOS 14 이상에서만 자동으로 지울 수 있어. 배경을 지운 PNG 를 넣어 줘")
            }
            guard let cut = cutout(img) else {
                throw PetError("사진에서 피사체를 찾지 못했어. 배경을 지운 PNG 를 넣어 줘")
            }
            img = cut
        }
        return trim(img) ?? img
    }

    /// 여러 프레임(GIF)의 배경을 함께 지운다.
    /// 프레임마다 따로 잘라내면 피사체가 튀므로, 원본 크기 그대로 마스크만 씌운 뒤
    /// 전 프레임을 아우르는 공통 상자로 한 번에 잘라낸다.
    static func prepare(frames fs: [CGImage]) throws -> [CGImage] {
        guard fs.count > 1 else { return [try prepare(fs[0])] }
        if fs.contains(where: hasTransparency) { return cropAll(fs) }   // 이미 배경이 없다
        guard #available(macOS 14.0, *) else {
            throw PetError("배경이 있는 GIF 는 macOS 14 이상에서만 자동으로 지울 수 있어. 배경을 지운 GIF 를 넣어 줘")
        }
        var cut: [CGImage] = []
        for f in fs {
            // 한 프레임에서 피사체를 놓치면 직전 프레임을 쓴다 — 그 프레임만 배경이 번쩍이는 것보다 낫다
            if let c = cutout(f, cropped: false) { cut.append(c) }
            else if let last = cut.last { cut.append(last) }
        }
        guard !cut.isEmpty else { throw PetError("GIF 에서 피사체를 찾지 못했어. 배경을 지운 GIF 를 넣어 줘") }
        return cropAll(cut)
    }

    /// 전 프레임의 불투명 영역을 합친 상자로 모두 잘라낸다 (프레임 간 위치 관계를 유지).
    static func cropAll(_ fs: [CGImage]) -> [CGImage] {
        var box: CGRect?
        for f in fs {
            guard let b = opaqueBounds(f) else { continue }
            box = box.map { $0.union(b) } ?? b
        }
        guard let box, box.width >= 1, box.height >= 1 else { return fs }
        return fs.map { $0.cropping(to: box) ?? $0 }
    }

    // MARK: 누끼

    /// 사진 앱의 "피사체 복사"와 같은 경로. 배경을 지운 이미지를 돌려준다.
    /// cropped: 피사체에 맞춰 잘라낼지. 여러 프레임을 다룰 때는 false 로 두고 나중에 공통 상자로 한 번에 자른다
    /// — 프레임마다 자르면 잘리는 범위가 달라져 피사체가 제자리에서 튄다.
    @available(macOS 14.0, *)
    static func cutout(_ image: CGImage, cropped: Bool = true) -> CGImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first,
              !observation.allInstances.isEmpty,
              let buffer = try? observation.generateMaskedImage(ofInstances: observation.allInstances,
                                                                from: handler,
                                                                croppedToInstancesExtent: cropped)
        else { return nil }
        let ci = CIImage(cvPixelBuffer: buffer)
        return CIContext().createCGImage(ci, from: ci.extent)
    }

    /// 실제로 비치는 픽셀이 있는지. 알파 채널이 있어도 전부 불투명한 PNG 가 흔해서 값을 본다.
    static func hasTransparency(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: break
        }
        guard let a = Raster.alphaMask(image) else { return false }
        // 가장자리만 훑어도 충분하다 — 배경이 남아 있으면 테두리가 불투명하다
        let w = image.width, h = image.height
        var clear = 0, total = 0
        for x in stride(from: 0, to: w, by: max(1, w / 64)) {
            for y in [0, h - 1] where y < h { if a[y * w + x] < 8 { clear += 1 }; total += 1 }
        }
        for y in stride(from: 0, to: h, by: max(1, h / 64)) {
            for x in [0, w - 1] where x < w { if a[y * w + x] < 8 { clear += 1 }; total += 1 }
        }
        return total > 0 && Double(clear) / Double(total) > 0.5
    }

    /// 불투명 픽셀이 차지하는 범위. 없으면 nil.
    static func opaqueBounds(_ image: CGImage) -> CGRect? {
        guard let a = Raster.alphaMask(image) else { return nil }
        let w = image.width, h = image.height
        var minX = w, maxX = -1, minY = h, maxY = -1
        for y in 0..<h {
            let base = y * w
            for x in 0..<w where a[base + x] > 8 {
                if x < minX { minX = x }; if x > maxX { maxX = x }
                if y < minY { minY = y }; if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// 투명한 여백을 잘라낸다.
    static func trim(_ image: CGImage) -> CGImage? {
        opaqueBounds(image).flatMap { image.cropping(to: $0) }
    }

    // MARK: 포즈 적용

    /// 문어는 팔·눈·입으로 상태를 드러내는데 이미지엔 그런 부위가 없다.
    /// 그 행들은 몸 전체의 움직임으로 바꿔 읽히게 한다.
    static func adjust(_ p0: DefaultPet.Pose, row: Int, frame: Int, of n: Int) -> DefaultPet.Pose {
        var p = p0
        let t = CGFloat(frame) / CGFloat(n)
        switch row {
        case 1, 2:                                   // 걷기 — 문어는 다리가 움직여서 티가 난다
            p.dy *= 1.6
            p.lean *= 1.5
        case 3:                                      // 손 흔들기 → 좌우로 몸을 흔든다
            p.lean = 0.26 * sin(t * 2 * .pi)      // 프레임이 4장뿐이라 4π 로 돌리면 전부 0 이 된다
            p.dy = 5 * abs(cos(t * 2 * .pi))
        case 6:                                      // 생각 — 살짝 기울여 갸웃
            p.lean = -0.10
            p.dy = 3 * sin(t * 2 * .pi)
        default: break
        }
        return p
    }

    /// 한 프레임 = 셀 하나. 이미지를 발밑 기준으로 변형해 그린다.
    static func render(_ subject: CGImage, row: Int, frame: Int, of n: Int) -> CGImage {
        let p = adjust(DefaultPet.pose(row: row, frame: frame, of: n), row: row, frame: frame, of: n)
        let cw = Int(cell.width), ch = Int(cell.height)
        let ctx = CGContext(data: nil, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high

        // 피사체를 셀에 맞춘 크기
        let maxH = cell.height * bodyRatio
        let k = min(maxH / CGFloat(subject.height), cell.width * 0.86 / CGFloat(subject.width))
        let bw = CGFloat(subject.width) * k, bh = CGFloat(subject.height) * k

        // pose 값은 192x208 문어 기준이라 셀 크기에 맞춰 환산한다
        let sx = cell.width / 192, sy = cell.height / 208
        let dx = p.dx * sx, dy = p.dy * sy
        let cx = cell.width / 2 + dx
        let feet = baselineY + dy

        // 그림자 — 뜰수록 옅어진다
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.16 * (1 - min(1, p.dy / 60))))
        ctx.fillEllipse(in: CGRect(x: cell.width / 2 - bw * 0.32, y: baselineY - 6,
                                   width: bw * 0.64, height: 11))

        ctx.saveGState()
        ctx.setAlpha(p.alpha)
        ctx.translateBy(x: cx, y: feet)     // 발밑이 원점
        ctx.rotate(by: -p.lean)
        ctx.scaleBy(x: p.squashX, y: p.squashY)
        ctx.draw(subject, in: CGRect(x: -bw / 2, y: 0, width: bw, height: bh))
        ctx.restoreGState()

        // 상태를 읽히게 하는 부가 표시 (생각 중 …, 잠 Zzz, 축하 별)
        drawExtra(p.extra, in: ctx, box: CGRect(x: cx - bw / 2, y: feet, width: bw, height: bh * p.squashY))
        return ctx.makeImage()!
    }

    /// 문어의 것과 같은 어휘. 위치만 피사체 상자 기준으로 잡는다.
    static func drawExtra(_ extra: DefaultPet.Extra, in c: CGContext, box: CGRect) {
        // 펫 몸 위가 아니라 빈 공간에 뜨므로, 바탕이 밝든 어둡든 보이게 흰 채움 + 어두운 테두리로 그린다.
        let fill = CGColor(gray: 1, alpha: 0.95)
        let edge = CGColor(red: 0.15, green: 0.12, blue: 0.12, alpha: 0.85)
        switch extra {
        case .dots(let k):
            for i in 0..<k {
                let r = CGRect(x: box.maxX + 4 + CGFloat(i) * 15, y: box.maxY - 14, width: 11, height: 11)
                c.setFillColor(fill); c.fillEllipse(in: r)
                c.setStrokeColor(edge); c.setLineWidth(2); c.strokeEllipse(in: r)
            }
        case .zzz(let k):
            for i in 0...k {
                let s: CGFloat = 13 + CGFloat(i) * 5
                let x = box.maxX - 6 + CGFloat(i) * 16, y = box.maxY + 6 + CGFloat(i) * 18
                let path = CGMutablePath()
                path.move(to: CGPoint(x: x, y: y + s)); path.addLine(to: CGPoint(x: x + s, y: y + s))
                path.addLine(to: CGPoint(x: x, y: y)); path.addLine(to: CGPoint(x: x + s, y: y))
                c.addPath(path); c.setStrokeColor(edge); c.setLineWidth(5); c.strokePath()
                c.addPath(path); c.setStrokeColor(fill); c.setLineWidth(2.5); c.strokePath()
            }
        case .star:
            c.setFillColor(CGColor(red: 1, green: 0.85, blue: 0.2, alpha: 1))
            for (sx, sy) in [(box.minX - 12, box.maxY * 0.8), (box.maxX + 12, box.maxY * 0.9), (box.midX, box.maxY + 18)] {
                let r: CGFloat = 7
                c.move(to: CGPoint(x: sx, y: sy + r))
                for i in 1..<10 {
                    let a = CGFloat(i) * .pi / 5 + .pi / 2, rr = i % 2 == 0 ? r : r * 0.45
                    c.addLine(to: CGPoint(x: sx + cos(a) * rr, y: sy + sin(a) * rr))
                }
                c.closePath(); c.fillPath()
            }
        case .slash(let k):
            c.setStrokeColor(CGColor(red: 1, green: 0.9, blue: 0.5, alpha: 0.95)); c.setLineWidth(5)
            for i in 0..<3 {
                let r = box.width * 0.55 + CGFloat(i) * 12 + k * 8
                c.addArc(center: CGPoint(x: box.midX, y: box.midY), radius: r,
                         startAngle: -0.7, endAngle: 0.7, clockwise: false)
                c.strokePath()
            }
        case .none, .sweat: break
        }
    }
}
