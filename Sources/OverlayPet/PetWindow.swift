import AppKit
import QuartzCore

/// 투명·무테·항상 위. 스프라이트 + 말풍선 + 이펙트를 한 창에 그린다.
final class PetWindow: NSWindow {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovableByWindowBackground = false
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 캐릭터 레이어 + 이펙트 레이어 + 말풍선. 투명 픽셀은 hitTest 에서 nil 을 돌려 아래 창으로 클릭이 통과한다.
final class PetView: NSView {
    private let spriteLayer = CALayer()
    private let effectLayer = CALayer()
    private let bubble = BubbleView()

    private(set) var sheet: SpriteSheet?
    private var alpha: [UInt8]?
    private var scale: CGFloat = 0.6
    private var baseFPS: Double = 8

    private var animSpecs: [String: AnimationSpec] = AnimationMap.defaults
    private(set) var currentState = "idle"
    private var spec = AnimationSpec(row: 0)
    private var frameIndex = 0
    private var timer: Timer?

    private var effect: Effect?
    private var effectFrame = 0
    private var effectTimer: Timer?

    private var dragOffset: NSPoint?
    var onMoved: ((NSPoint) -> Void)?
    var onRightClick: ((NSEvent) -> Void)?

    // 레이아웃: 아래 스프라이트, 위 말풍선
    static let bubbleHeight: CGFloat = 64
    var spriteSize: CGSize {
        guard let s = sheet else { return CGSize(width: 192 * scale, height: 208 * scale) }
        return CGSize(width: CGFloat(s.frameWidth) * scale, height: CGFloat(s.frameHeight) * scale)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear
        spriteLayer.magnificationFilter = .nearest
        spriteLayer.minificationFilter = .trilinear
        spriteLayer.contentsGravity = .resize
        effectLayer.magnificationFilter = .nearest
        effectLayer.contentsGravity = .resize
        effectLayer.isHidden = true
        layer?.addSublayer(spriteLayer)
        layer?.addSublayer(effectLayer)
        bubble.isHidden = true
        addSubview(bubble)
        // 암묵적 애니메이션 끄기 (contentsRect 바꿀 때 슬라이드 방지)
        spriteLayer.actions = ["contents": NSNull(), "contentsRect": NSNull(), "bounds": NSNull(), "position": NSNull()]
        effectLayer.actions = spriteLayer.actions
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func configure(config: Config) {
        scale = CGFloat(config.scale)
        baseFPS = config.fps
        animSpecs = AnimationMap.resolve(config)
        needsLayout = true
    }

    func setSheet(_ sheet: SpriteSheet?) {
        self.sheet = sheet
        alpha = sheet.flatMap { Raster.alphaMask($0.image) }
        spriteLayer.contents = sheet?.image
        needsLayout = true
        play(state: currentState, force: true)
    }

    override func layout() {
        super.layout()
        let sz = spriteSize
        let x = (bounds.width - sz.width) / 2
        spriteLayer.frame = CGRect(x: x, y: bounds.height - sz.height, width: sz.width, height: sz.height)
        bubble.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Self.bubbleHeight)
        layoutEffect()
    }

    // MARK: 애니메이션

    func play(state: String, force: Bool = false) {
        guard force || state != currentState else { return }
        currentState = state
        spec = animSpecs[state] ?? animSpecs["idle"] ?? AnimationSpec(row: 0)
        if let s = sheet, spec.row >= s.rows { spec.row = 0 }
        frameIndex = 0
        timer?.invalidate()
        drawFrame()
        let fps = max(1, baseFPS * spec.speed)
        timer = Timer.scheduledTimer(withTimeInterval: 1 / fps, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func tick() {
        guard let s = sheet else { return }
        let count = max(1, s.frameCounts[min(spec.row, s.frameCounts.count - 1)])
        frameIndex += 1
        if frameIndex >= count {
            if spec.once, let next = spec.then { play(state: next); return }
            frameIndex = 0
        }
        drawFrame()
    }

    private func drawFrame() {
        guard let s = sheet else { return }
        spriteLayer.contentsRect = s.contentsRect(row: spec.row, column: frameIndex)
    }

    // MARK: 이펙트

    func playEffect(_ effect: Effect?) {
        effectTimer?.invalidate()
        self.effect = effect
        guard let e = effect else { effectLayer.isHidden = true; return }
        effectLayer.contents = e.image
        effectFrame = 0
        effectLayer.isHidden = false
        layoutEffect()
        effectLayer.contentsRect = e.contentsRect(frame: 0)
        effectTimer = Timer.scheduledTimer(withTimeInterval: 1 / max(1, e.manifest.fps), repeats: true) { [weak self] _ in
            guard let self, let e = self.effect else { return }
            self.effectFrame += 1
            if self.effectFrame >= e.manifest.frames {
                if e.manifest.loop { self.effectFrame = 0 } else { self.playEffect(nil); return }
            }
            self.effectLayer.contentsRect = e.contentsRect(frame: self.effectFrame)
        }
        RunLoop.main.add(effectTimer!, forMode: .common)
    }

    private func layoutEffect() {
        guard let e = effect else { return }
        let m = e.manifest
        let w = CGFloat(m.frameWidth) * scale * CGFloat(m.scale), h = CGFloat(m.frameHeight) * scale * CGFloat(m.scale)
        let sp = spriteLayer.frame
        let cx = sp.midX + CGFloat(m.offsetX) * scale
        let y: CGFloat = m.anchor == "bottom" ? sp.maxY - h : sp.midY - h / 2
        effectLayer.frame = CGRect(x: cx - w / 2, y: y - CGFloat(m.offsetY) * scale, width: w, height: h)
    }

    // MARK: 말풍선

    private var bubbleTimer: Timer?
    func say(_ text: String, seconds: Double) {
        bubble.text = text
        bubble.isHidden = false
        bubbleTimer?.invalidate()
        bubbleTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in self?.bubble.isHidden = true }
    }

    // MARK: 클릭 통과 / 드래그

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        if !bubble.isHidden, bubble.frame.contains(p) { return self }
        return spriteAlpha(at: p) > 8 ? self : nil
    }

    private func spriteAlpha(at p: NSPoint) -> UInt8 {
        guard let s = sheet, let a = alpha, spriteLayer.frame.contains(p) else { return 0 }
        let fx = (p.x - spriteLayer.frame.minX) / scale
        let fy = (p.y - spriteLayer.frame.minY) / scale
        let x = Int(fx) + frameIndex * s.frameWidth
        let y = Int(fy) + spec.row * s.frameHeight
        guard x >= 0, y >= 0, x < s.image.width, y < s.image.height else { return 0 }
        return a[y * s.image.width + x]
    }

    override func mouseDown(with event: NSEvent) {
        dragOffset = event.locationInWindow
    }
    override func mouseDragged(with event: NSEvent) {
        guard let w = window, let off = dragOffset else { return }
        let m = NSEvent.mouseLocation
        w.setFrameOrigin(NSPoint(x: m.x - off.x, y: m.y - off.y))
    }
    override func mouseUp(with event: NSEvent) {
        if dragOffset != nil, let w = window { onMoved?(w.frame.origin) }
        dragOffset = nil
    }
    override func rightMouseDown(with event: NSEvent) { onRightClick?(event) }
}

/// 둥근 말풍선. 시스템 알림 권한 없이 진행 상황을 보여준다.
final class BubbleView: NSView {
    var text: String = "" { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty else { return }
        let para = NSMutableParagraphStyle(); para.alignment = .center; para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.black, .paragraphStyle: para,
        ]
        let maxW = bounds.width - 16
        let size = (text as NSString).boundingRect(with: NSSize(width: maxW - 20, height: 40), options: [.usesLineFragmentOrigin], attributes: attrs).size
        let w = min(maxW, size.width + 24), h = min(44, size.height + 14)
        let box = NSRect(x: (bounds.width - w) / 2, y: bounds.height - h - 10, width: w, height: h)
        let path = NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10)
        // 꼬리
        path.move(to: NSPoint(x: box.midX - 6, y: box.maxY))
        path.line(to: NSPoint(x: box.midX, y: box.maxY + 8))
        path.line(to: NSPoint(x: box.midX + 6, y: box.maxY))
        path.close()
        NSColor(white: 1, alpha: 0.95).setFill(); path.fill()
        NSColor(white: 0, alpha: 0.15).setStroke(); path.lineWidth = 1; path.stroke()
        (text as NSString).draw(in: box.insetBy(dx: 10, dy: 6), withAttributes: attrs)
    }
}
