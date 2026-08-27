import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// 캐릭터를 아직 안 가져왔을 때 쓰는 기본 펫. 외부 에셋 없이 코드로 그린다 (문어).
/// maple-hatch-pet 과 같은 192x208 / 8열 9행 시트로 만들어 ~/.claude/pet/pets/default 에 둔다.
enum DefaultPet {
    static let id = "default"
    static let version = 3
    static let cellW = 192, cellH = 208
    static let counts = SpriteSheet.defaultFrameCounts
    static let baselineY: CGFloat = 20   // 셀 바닥에서 발까지 (CG 좌표, 아래가 0)

    static func ensureInstalled() -> String? {
        let dir = Paths.petDirectory(id)
        let manifestURL = dir.appendingPathComponent("pet.json")
        if let data = try? Data(contentsOf: manifestURL),
           let m = try? JSONDecoder().decode(PetManifest.self, from: data),
           m.spriteVersionNumber == version { return id }
        do { try generate(into: dir); return id } catch { return nil }
    }

    static func generate(into dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let w = cellW * 8, h = cellH * 9
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw PetError("비트맵 생성 실패") }
        ctx.setShouldAntialias(true)
        for row in 0..<9 {
            for col in 0..<counts[row] {
                ctx.saveGState()
                ctx.translateBy(x: CGFloat(col * cellW), y: CGFloat(h - (row + 1) * cellH))
                draw(row: row, frame: col, of: counts[row], in: ctx)
                ctx.restoreGState()
            }
        }
        guard let img = ctx.makeImage(),
              let dst = CGImageDestinationCreateWithURL(dir.appendingPathComponent("spritesheet.png") as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw PetError("PNG 저장 실패") }
        CGImageDestinationAddImage(dst, img, nil)
        guard CGImageDestinationFinalize(dst) else { throw PetError("PNG 저장 실패") }
        let manifest = PetManifest(id: id, displayName: "Octo", description: "기본 펫 (코드로 그린 문어)",
                                   spriteVersionNumber: version, spritesheetPath: "spritesheet.png",
                                   frameWidth: cellW, frameHeight: cellH, columns: 8, rows: 9, frameCounts: counts)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(manifest).write(to: dir.appendingPathComponent("pet.json"))
    }

    // MARK: 그리기

    struct Pose {
        var squashX: CGFloat = 1, squashY: CGFloat = 1
        var dx: CGFloat = 0, dy: CGFloat = 0
        var lean: CGFloat = 0            // 라디안, +면 오른쪽으로 기움
        var alpha: CGFloat = 1
        var eye: Eye = .open
        var lookX: CGFloat = 0, lookY: CGFloat = 0
        var mouth: Mouth = .smile
        var armL: CGFloat? = nil, armR: CGFloat? = nil   // 팔 각도(라디안), nil 이면 내림
        var brow = false
        var extra: Extra = .none
    }
    enum Eye { case open, closed, cross, happy }
    enum Mouth { case smile, open, flat, wavy }
    enum Extra { case none, dots(Int), zzz(Int), slash(CGFloat), sweat, star(CGFloat) }

    static func pose(row: Int, frame: Int, of n: Int) -> Pose {
        let t = CGFloat(frame) / CGFloat(n)             // 0..<1
        let s = sin(t * 2 * .pi)
        var p = Pose()
        switch row {
        case 0: // 서기: 숨쉬기
            p.squashY = 1 + 0.04 * s; p.squashX = 1 - 0.03 * s
            p.eye = frame == n - 1 ? .closed : .open
        case 1, 2: // 걷기
            let dir: CGFloat = row == 1 ? 1 : -1
            p.lean = 0.18 * dir
            p.dy = abs(s) * 14
            p.squashY = 1 - 0.08 * abs(s); p.squashX = 1 + 0.06 * abs(s)
            p.lookX = 6 * dir
            p.armL = dir > 0 ? nil : 0.9 + 0.4 * s; p.armR = dir > 0 ? 0.9 + 0.4 * s : nil
        case 3: // 손 흔들기
            p.armR = 1.9 + 0.5 * sin(t * 4 * .pi)
            p.eye = .happy; p.mouth = .open
            p.squashY = 1 + 0.03 * s
        case 4: // 점프
            let ys: [CGFloat] = [-8, 30, 52, 30, -6]
            let sq: [CGFloat] = [0.78, 1.15, 1.05, 1.1, 0.8]
            p.dy = ys[frame]; p.squashY = sq[frame]; p.squashX = 2 - sq[frame]
            p.eye = .happy; p.mouth = .open
            p.armL = frame >= 1 && frame <= 3 ? 2.2 : nil; p.armR = p.armL
            if frame == 2 { p.extra = .star(1) }
        case 5: // 유령
            p.alpha = 0.55; p.dy = 24 + 10 * s; p.eye = .cross; p.mouth = .wavy
            p.squashX = 1 + 0.05 * s; p.lean = 0.08 * s
        case 6: // 생각
            p.lookX = 8; p.lookY = 8; p.mouth = .flat
            p.armR = 1.2
            p.extra = .dots(frame % 4)
            p.squashY = 1 + 0.02 * s
        case 7: // 공격: 돌진
            let lunge: [CGFloat] = [-10, -18, 24, 34, 18, 0]
            p.dx = lunge[frame]; p.lean = lunge[frame] / 140
            p.squashX = frame == 2 || frame == 3 ? 1.18 : 0.95; p.squashY = 2 - p.squashX
            p.brow = true; p.mouth = .open; p.lookX = 6
            p.armR = frame >= 2 ? 0.2 : 2.4
            if frame == 2 || frame == 3 { p.extra = .slash(CGFloat(frame - 2)) }
        default: // 눕기 / 잠
            p.squashY = 0.62; p.squashX = 1.28; p.eye = .closed; p.mouth = .flat
            p.dy = -4 + 2 * s
            p.extra = .zzz(frame % 3)
        }
        return p
    }

    // 문어 (코랄 오렌지)
    static let skin = CGColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1)
    static let skinDark = CGColor(red: 0.62, green: 0.30, blue: 0.22, alpha: 1)
    static let skinLight = CGColor(red: 0.96, green: 0.66, blue: 0.52, alpha: 1)
    static let ink = CGColor(red: 0.20, green: 0.12, blue: 0.10, alpha: 1)

    static func draw(row: Int, frame: Int, of n: Int, in c: CGContext) {
        let p = pose(row: row, frame: frame, of: n)
        let t = CGFloat(frame) / CGFloat(n)
        let cx = CGFloat(cellW) / 2 + p.dx
        let base = baselineY + p.dy
        let headW: CGFloat = 104 * p.squashX, headH: CGFloat = 96 * p.squashY
        let headY: CGFloat = 26   // 다리 위에 머리

        c.setAlpha(p.alpha)
        c.setFillColor(CGColor(gray: 0, alpha: 0.16 * (1 - min(1, p.dy / 60))))
        c.fillEllipse(in: CGRect(x: cx - 40, y: baselineY - 6, width: 80, height: 11))

        c.translateBy(x: cx, y: base)
        c.rotate(by: -p.lean)
        c.setLineCap(.round); c.setLineJoin(.round)

        // 다리 8개: 뒤 4 → 머리 → 앞 4 순으로 그려 입체감
        let legCount = 8
        func leg(_ i: Int, front: Bool) {
            let k = CGFloat(i) - CGFloat(legCount - 1) / 2          // -3.5 … 3.5
            let x0 = k * headW * 0.11
            let wave = sin(t * 2 * .pi + CGFloat(i) * 0.9) * (row == 8 ? 3 : 9)
            var raise: CGFloat = 0
            if let a = p.armR, i == legCount - 1 { raise = sin(a) * 40 }
            if let a = p.armL, i == 0 { raise = sin(a) * 40 }
            let dir: CGFloat = k < 0 ? -1 : 1
            let ex = x0 + dir * (14 + abs(k) * 7) + (p.lookX * 0.4), ey = -2 + wave * 0.4 + raise
            let path = CGMutablePath()
            path.move(to: CGPoint(x: x0, y: headY + 10))
            path.addCurve(to: CGPoint(x: ex, y: ey),
                          control1: CGPoint(x: x0 + dir * 4, y: headY - 6 + wave),
                          control2: CGPoint(x: ex - dir * 10, y: ey + 12 + wave * 0.5))
            c.addPath(path); c.setStrokeColor(skinDark); c.setLineWidth(15); c.strokePath()
            c.addPath(path); c.setStrokeColor(front ? skin : skinDark.copy(alpha: 0.9)!); c.setLineWidth(10); c.strokePath()
            if front {   // 빨판
                c.setFillColor(skinLight)
                c.fillEllipse(in: CGRect(x: ex - dir * 6 - 3, y: ey + 3, width: 5, height: 5))
                c.fillEllipse(in: CGRect(x: ex - dir * 13 - 3, y: ey + 7, width: 4, height: 4))
            }
        }
        for i in [1, 3, 4, 6] { leg(i, front: false) }

        // 머리 (아래가 살짝 넓은 돔)
        let head = CGMutablePath()
        head.move(to: CGPoint(x: -headW / 2, y: headY + headH * 0.30))
        head.addCurve(to: CGPoint(x: headW / 2, y: headY + headH * 0.30),
                      control1: CGPoint(x: -headW * 0.55, y: headY + headH * 1.15),
                      control2: CGPoint(x: headW * 0.55, y: headY + headH * 1.15))
        head.addCurve(to: CGPoint(x: -headW / 2, y: headY + headH * 0.30),
                      control1: CGPoint(x: headW * 0.45, y: headY - headH * 0.05),
                      control2: CGPoint(x: -headW * 0.45, y: headY - headH * 0.05))
        head.closeSubpath()
        c.addPath(head); c.setFillColor(skin); c.fillPath()
        c.addPath(head); c.setStrokeColor(skinDark); c.setLineWidth(3.5); c.strokePath()
        // 하이라이트 + 점 무늬
        c.setFillColor(skinLight.copy(alpha: 0.55)!)
        c.fillEllipse(in: CGRect(x: -headW * 0.36, y: headY + headH * 0.62, width: headW * 0.22, height: headH * 0.20))
        c.setFillColor(skinDark.copy(alpha: 0.35)!)
        for (dx, dy, r) in [(-0.30, 0.42, 5.0), (0.34, 0.50, 4.0), (0.22, 0.78, 3.5), (-0.12, 0.86, 3.0)] {
            c.fillEllipse(in: CGRect(x: headW * dx - r, y: headY + headH * dy - r, width: r * 2, height: r * 2))
        }
        // 볼
        c.setFillColor(CGColor(red: 1, green: 0.5, blue: 0.5, alpha: 0.45))
        c.fillEllipse(in: CGRect(x: -headW * 0.40, y: headY + headH * 0.28, width: 17, height: 9))
        c.fillEllipse(in: CGRect(x: headW * 0.40 - 17, y: headY + headH * 0.28, width: 17, height: 9))

        // 눈
        let ey = headY + headH * 0.46 + p.lookY, ex: CGFloat = headW * 0.20
        for side: CGFloat in [-1, 1] {
            let x = side * ex + p.lookX
            switch p.eye {
            case .open:
                c.setFillColor(.white); c.fillEllipse(in: CGRect(x: x - 11, y: ey - 12, width: 22, height: 26))
                c.setFillColor(ink); c.fillEllipse(in: CGRect(x: x - 7 + p.lookX * 0.2, y: ey - 8, width: 14, height: 17))
                c.setFillColor(.white)
                c.fillEllipse(in: CGRect(x: x - 1 + p.lookX * 0.2, y: ey + 2, width: 6, height: 6))
                c.fillEllipse(in: CGRect(x: x - 5 + p.lookX * 0.2, y: ey - 5, width: 3, height: 3))
            case .closed:
                c.setStrokeColor(ink); c.setLineWidth(3.5)
                c.addArc(center: CGPoint(x: x, y: ey + 4), radius: 9, startAngle: .pi + 0.3, endAngle: 2 * .pi - 0.3, clockwise: false); c.strokePath()
            case .happy:
                c.setStrokeColor(ink); c.setLineWidth(3.5)
                c.addArc(center: CGPoint(x: x, y: ey - 3), radius: 9, startAngle: 0.2, endAngle: .pi - 0.2, clockwise: false); c.strokePath()
            case .cross:
                c.setStrokeColor(ink); c.setLineWidth(3.5)
                c.move(to: CGPoint(x: x - 8, y: ey - 8)); c.addLine(to: CGPoint(x: x + 8, y: ey + 8))
                c.move(to: CGPoint(x: x - 8, y: ey + 8)); c.addLine(to: CGPoint(x: x + 8, y: ey - 8)); c.strokePath()
            }
            if p.brow {
                c.setStrokeColor(ink); c.setLineWidth(4)
                c.move(to: CGPoint(x: x - 12, y: ey + 19 + (side > 0 ? 6 : 0)))
                c.addLine(to: CGPoint(x: x + 12, y: ey + 19 + (side > 0 ? 0 : 6))); c.strokePath()
            }
        }
        // 입
        let my = headY + headH * 0.24, mx = p.lookX * 0.5
        c.setStrokeColor(ink); c.setLineWidth(3)
        switch p.mouth {
        case .smile:
            c.addArc(center: CGPoint(x: mx, y: my + 5), radius: 9, startAngle: .pi + 0.35, endAngle: 2 * .pi - 0.35, clockwise: false); c.strokePath()
        case .open:
            c.setFillColor(ink); c.fillEllipse(in: CGRect(x: mx - 8, y: my - 8, width: 16, height: 13))
            c.setFillColor(CGColor(red: 0.95, green: 0.45, blue: 0.5, alpha: 1)); c.fillEllipse(in: CGRect(x: mx - 4, y: my - 8, width: 8, height: 5))
        case .flat:
            c.move(to: CGPoint(x: mx - 7, y: my)); c.addLine(to: CGPoint(x: mx + 7, y: my)); c.strokePath()
        case .wavy:
            c.move(to: CGPoint(x: mx - 10, y: my))
            for i in 1...4 { c.addLine(to: CGPoint(x: mx - 10 + CGFloat(i) * 5, y: my + (i % 2 == 1 ? 4 : -4))) }
            c.strokePath()
        }

        for i in [0, 2, 5, 7] { leg(i, front: true) }

        // 부가 요소
        let top = headY + headH
        c.setFillColor(ink); c.setStrokeColor(ink)
        switch p.extra {
        case .none: break
        case .dots(let k):
            for i in 0..<k { c.fillEllipse(in: CGRect(x: headW * 0.45 + CGFloat(i) * 12, y: top + 8, width: 7, height: 7)) }
        case .zzz(let k):
            for i in 0...k {
                let s: CGFloat = 10 + CGFloat(i) * 4, x = headW * 0.35 + CGFloat(i) * 14, y = top + 4 + CGFloat(i) * 16
                c.setLineWidth(2.5)
                c.move(to: CGPoint(x: x, y: y + s)); c.addLine(to: CGPoint(x: x + s, y: y + s))
                c.addLine(to: CGPoint(x: x, y: y)); c.addLine(to: CGPoint(x: x + s, y: y)); c.strokePath()
            }
        case .slash(let k):
            c.setStrokeColor(CGColor(red: 1, green: 0.9, blue: 0.5, alpha: 0.95)); c.setLineWidth(5)
            for i in 0..<3 {
                let r: CGFloat = 54 + CGFloat(i) * 12 + k * 8
                c.addArc(center: CGPoint(x: headW * 0.3, y: headY + headH * 0.4), radius: r, startAngle: -0.7, endAngle: 0.7, clockwise: false); c.strokePath()
            }
        case .sweat:
            c.setFillColor(CGColor(red: 0.4, green: 0.7, blue: 1, alpha: 1))
            c.fillEllipse(in: CGRect(x: headW * 0.45, y: headY + headH * 0.7, width: 8, height: 12))
        case .star:
            c.setFillColor(CGColor(red: 1, green: 0.85, blue: 0.2, alpha: 1))
            for (sx, sy): (CGFloat, CGFloat) in [(-headW * 0.75, top * 0.7), (headW * 0.75, top * 0.85), (0, top + 22)] {
                let r: CGFloat = 7
                c.move(to: CGPoint(x: sx, y: sy + r))
                for i in 1..<10 {
                    let a = CGFloat(i) * .pi / 5 + .pi / 2, rr = i % 2 == 0 ? r : r * 0.45
                    c.addLine(to: CGPoint(x: sx + cos(a) * rr, y: sy + sin(a) * rr))
                }
                c.closePath(); c.fillPath()
            }
        }
    }
}
