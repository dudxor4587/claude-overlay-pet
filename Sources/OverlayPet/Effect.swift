import Foundation
import CoreGraphics

/// 이펙트 레이어. 에셋은 사용자가 직접 넣는다:
///   ~/.claude/pet/effects/<name>/effect.json + sheet.png
/// effect.json 예:
///   {"frameWidth":200,"frameHeight":200,"frames":12,"columns":6,"fps":12,
///    "loop":false,"anchor":"center","offsetX":0,"offsetY":40,"scale":1}
/// 공식 API 로 스킬 이펙트를 받을 수 있게 되면 fetcher 가 같은 포맷으로 떨어뜨리면 된다.
struct EffectManifest: Codable {
    var frameWidth: Int
    var frameHeight: Int
    var frames: Int
    var columns: Int?
    var fps: Double = 12
    var loop: Bool = false
    /// "center" | "bottom" — 캐릭터 기준 정렬
    var anchor: String = "center"
    var offsetX: Double = 0
    var offsetY: Double = 0
    var scale: Double = 1
    var sheetPath: String = "sheet.png"
    // 메뉴 표시용 메타 (가져오기 시 기록)
    var skill: String?
    var koreanName: String?
    var variant: String?
    var tier: String?
    var tierOrder: Int?
    var path: String?
}

/// 설치된 이펙트의 매니페스트만 (시트는 안 읽음) — 메뉴 구성용
struct EffectInfo {
    let name: String
    let manifest: EffectManifest
    var tier: String { manifest.tier ?? "기타" }
    var tierOrder: Int { manifest.tierOrder ?? 99 }
    var skill: String { manifest.skill ?? name }
    /// 메뉴 표시용: 한글 이름이 있으면 한글, 없으면 영문
    var skillTitle: String { manifest.koreanName ?? SkillNames.korean(skill) ?? skill }
    var variant: String { manifest.variant ?? "" }

    static func all() -> [EffectInfo] {
        Effect.installed().compactMap { name in
            guard let data = try? Data(contentsOf: Paths.effectDirectory(name).appendingPathComponent("effect.json")),
                  let m = try? JSONDecoder().decode(EffectManifest.self, from: data) else { return nil }
            return EffectInfo(name: name, manifest: m)
        }
    }
}

struct Effect {
    let name: String
    let manifest: EffectManifest
    let image: CGImage
    var columns: Int { manifest.columns ?? max(1, image.width / manifest.frameWidth) }

    func contentsRect(frame: Int) -> CGRect {
        let c = frame % columns, r = frame / columns
        return CGRect(x: CGFloat(c * manifest.frameWidth) / CGFloat(image.width),
                      y: CGFloat(r * manifest.frameHeight) / CGFloat(image.height),
                      width: CGFloat(manifest.frameWidth) / CGFloat(image.width),
                      height: CGFloat(manifest.frameHeight) / CGFloat(image.height))
    }

    static func load(name: String) throws -> Effect {
        let dir = Paths.effectDirectory(name)
        let manifest = try JSONDecoder().decode(EffectManifest.self, from: Data(contentsOf: dir.appendingPathComponent("effect.json")))
        guard let image = SpriteSheet.loadImage(dir.appendingPathComponent(manifest.sheetPath)) else {
            throw PetError("이펙트 시트를 읽을 수 없음: \(name)")
        }
        return Effect(name: name, manifest: manifest, image: image)
    }

    static func installed() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: Paths.effects.path)) ?? [])
            .filter { FileManager.default.fileExists(atPath: Paths.effectDirectory($0).appendingPathComponent("effect.json").path) }
            .sorted()
    }
}
