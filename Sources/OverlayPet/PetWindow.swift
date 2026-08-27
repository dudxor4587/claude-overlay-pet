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
        acceptsMouseMovedEvents = true   // 호버 감지
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 캐릭터 레이어 + 이펙트 레이어 + 말풍선. 투명 픽셀은 hitTest 에서 nil 을 돌려 아래 창으로 클릭이 통과한다.
final class PetView: NSView {
    private let spriteLayer = CALayer()
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

    /// 동시에 재생 중인 이펙트들 (스킬 하나 = Effect + Hit + … 를 겹쳐서)
    private final class EffectPlayer {
        let effect: Effect
        let offsetX: CGFloat
        let layer = CALayer()
        var frame = 0
        var timer: Timer?
        init(_ e: Effect, offsetX: CGFloat) { effect = e; self.offsetX = offsetX }
        deinit { timer?.invalidate(); layer.removeFromSuperlayer() }
    }
    private var players: [EffectPlayer] = []
    private var scheduled: [DispatchWorkItem] = []

    private var dragOffset: NSPoint?
    var onMoved: ((NSPoint) -> Void)?
    var onRightClick: ((NSEvent) -> Void)?
    var onHover: (() -> Void)?
    private var hovering = false
    private var lastHover: TimeInterval = 0

    // 레이아웃: 창을 스프라이트보다 넉넉히 잡아 큰 이펙트가 잘리지 않게 한다. 투명 영역은 클릭 통과.
    static let bubbleHeight: CGFloat = 110   // 세션 4줄까지
    static let canvasWidth: CGFloat = 520
    static let canvasTopPad: CGFloat = 220   // 스프라이트 위 이펙트 여유
    static let canvasSidePad: CGFloat = 0
    var canvasSize: CGSize {
        CGSize(width: max(spriteSize.width, Self.canvasWidth), height: spriteSize.height + Self.bubbleHeight + Self.canvasTopPad)
    }
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
        layer?.addSublayer(spriteLayer)
        bubble.isHidden = true
        addSubview(bubble)
        // 암묵적 애니메이션 끄기 (contentsRect 바꿀 때 슬라이드 방지)
        spriteLayer.actions = ["contents": NSNull(), "contentsRect": NSNull(), "bounds": NSNull(), "position": NSNull()]
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let over = spriteAlpha(at: p) > 8
        if over && !hovering, Date().timeIntervalSince1970 - lastHover > 2.5 {
            lastHover = Date().timeIntervalSince1970
            onHover?()
        }
        hovering = over
    }
    override func mouseExited(with event: NSEvent) { hovering = false }

    /// 이펙트가 재생 중이거나 예약돼 있으면 true (갤러리가 겹치지 않게)
    var isPlayingEffects: Bool { !players.isEmpty || pendingCount > 0 }
    private var pendingCount = 0

    func configure(config: Config) {
        scale = CGFloat(config.scale)
        baseFPS = config.fps
        animSpecs = AnimationMap.resolve(config)
        needsLayout = true
    }

    /// 서기(0행) 프레임에서 머리 꼭대기까지의 셀 안 여백(픽셀). 말풍선을 머리 바로 위에 붙이기 위해.
    private var headInset: CGFloat = 0

    func setSheet(_ sheet: SpriteSheet?) {
        self.sheet = sheet
        alpha = sheet.flatMap { Raster.alphaMask($0.image) }
        spriteLayer.contents = sheet?.image
        headInset = measureHeadInset()
        needsLayout = true
        play(state: currentState, force: true)
    }

    /// 머리 부분(꼭대기부터 40px)의 가로 중심. 무기·이펙트로 전체 폭이 치우쳐도 머리 위에 말풍선이 오게.
    private var headCenterX: CGFloat = 96

    /// 발 위치(셀 안 y)와 몸통 가로 중심 — 이펙트 정렬용
    private var footY: CGFloat = 188
    private var bodyCenterX: CGFloat = 96

    private func measureHeadInset() -> CGFloat {
        guard let s = sheet, let a = alpha else { return 0 }
        let w = s.image.width
        var top: Int?, bottom = 0
        var sumX = 0, count = 0, allX = 0, allCount = 0
        for y in 0..<s.frameHeight {
            let rowBase = y * w
            for x in 0..<s.frameWidth where x < w && a[rowBase + x] > 8 {   // 0행 0열 프레임만
                if top == nil { top = y }
                if y - (top ?? y) <= 40 { sumX += x; count += 1 }
                allX += x; allCount += 1
                bottom = y
            }
        }
        headCenterX = count > 0 ? CGFloat(sumX) / CGFloat(count) : CGFloat(s.frameWidth) / 2
        bodyCenterX = allCount > 0 ? CGFloat(allX) / CGFloat(allCount) : CGFloat(s.frameWidth) / 2
        footY = CGFloat(bottom + 1)
        return CGFloat(top ?? 0)
    }

    override func layout() {
        super.layout()
        let sz = spriteSize
        let x = (bounds.width - sz.width) / 2
        spriteLayer.frame = CGRect(x: x, y: bounds.height - sz.height, width: sz.width, height: sz.height)
        let headTop = spriteLayer.frame.minY + headInset * scale
        // 말풍선 폭은 창 전체, 중심은 머리 위에
        let cx = spriteLayer.frame.minX + headCenterX * scale
        bubble.frame = CGRect(x: cx - bounds.width / 2, y: max(0, headTop - Self.bubbleHeight), width: bounds.width, height: Self.bubbleHeight)
        layoutEffect()
    }

    // MARK: 애니메이션

    /// 다른 세션 이벤트 등: 한 번만 재생하고 원래 상태로 돌아간다.
    func playOnce(state: String) {
        let back = interruptedState ?? currentState
        play(state: state, force: true, once: true, then: back)
        interruptedState = back
    }
    private var interruptedState: String?

    func play(state: String, force: Bool = false, once: Bool? = nil, then: String? = nil) {
        guard force || state != currentState else { return }
        if once == nil { interruptedState = nil }
        currentState = state
        spec = animSpecs[state] ?? animSpecs["idle"] ?? AnimationSpec(row: 0)
        if let once { spec.once = once; spec.then = then }
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
            if spec.once, let next = spec.then { interruptedState = nil; play(state: next, force: true); return }
            frameIndex = 0
        }
        drawFrame()
    }

    private func drawFrame() {
        guard let s = sheet else { return }
        spriteLayer.contentsRect = s.contentsRect(row: spec.row, column: frameIndex)
    }

    // MARK: 이펙트

    func playEffect(_ effect: Effect?) { playEffects(effect.map { [$0] } ?? []) }

    /// 스킬 조각들을 EffectSequencer 순서대로 재생. 이전에 재생 중이던 것은 정리.
    func playEffects(_ effects: [Effect]) {
        players.removeAll()
        scheduled.forEach { $0.cancel() }; scheduled.removeAll(); pendingCount = 0
        for item in EffectSequencer.plan(effects) {
            if item.delay <= 0 { start(item.effect, offsetX: CGFloat(item.offsetX)); continue }
            let w = DispatchWorkItem { [weak self] in self?.pendingCount -= 1; self?.start(item.effect, offsetX: CGFloat(item.offsetX)) }
            scheduled.append(w); pendingCount += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + item.delay, execute: w)
        }
    }

    private func start(_ e: Effect, offsetX: CGFloat) {
        do {
            let p = EffectPlayer(e, offsetX: offsetX)
            p.layer.magnificationFilter = .nearest
            p.layer.contentsGravity = .resize
            p.layer.actions = spriteLayer.actions
            p.layer.contents = e.image
            p.layer.contentsRect = e.contentsRect(frame: 0)
            layer?.addSublayer(p.layer)
            players.append(p)
            p.timer = Timer.scheduledTimer(withTimeInterval: 1 / max(1, e.manifest.fps), repeats: true) { [weak self, weak p] _ in
                guard let self, let p else { return }
                p.frame += 1
                if p.frame >= e.manifest.frames {
                    if e.manifest.loop { p.frame = 0 } else { self.players.removeAll { $0 === p }; return }
                }
                p.layer.contentsRect = e.contentsRect(frame: p.frame)
            }
            RunLoop.main.add(p.timer!, forMode: .common)
        }
        layoutEffect()
    }

    private func layoutEffect() {
        for p in players {
            let m = p.effect.manifest
            var w = CGFloat(m.frameWidth) * scale * CGFloat(m.scale), h = CGFloat(m.frameHeight) * scale * CGFloat(m.scale)
            // 창보다 크면 창에 맞춰 축소 (6차 오리진 같은 대형 이펙트)
            let fit = min(1, bounds.width / w, (bounds.height - 8) / h)
            w *= fit; h *= fit
            let sp = spriteLayer.frame
            let cx = sp.minX + bodyCenterX * scale + (CGFloat(m.offsetX) + p.offsetX) * scale
            let feet = sp.minY + footY * scale
            let y: CGFloat = m.anchor == "bottom" ? feet - h : (sp.minY + headInset * scale + feet) / 2 - h / 2
            p.layer.frame = CGRect(x: cx - w / 2, y: y - CGFloat(m.offsetY) * scale, width: w, height: h)
        }
    }

    // MARK: 말풍선

    private var bubbleTimer: Timer?
    private var statusLines: [String] = []
    private var transient: String?

    /// 세션 상태 패널 (지속 표시). 비어 있으면 숨김.
    func setStatus(_ lines: [String]) {
        statusLines = lines
        refreshBubble()
    }

    /// 일시 메시지: 잠깐 패널을 덮었다가 되돌린다.
    func say(_ text: String, seconds: Double) {
        transient = text
        bubbleTimer?.invalidate()
        bubbleTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.transient = nil; self?.refreshBubble()
        }
        refreshBubble()
    }

    private func refreshBubble() {
        let lines = transient.map { [$0] } ?? statusLines
        bubble.lines = lines
        bubble.isHidden = lines.isEmpty
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

/// 둥근 말풍선. 시스템 알림 권한 없이 진행 상황을 보여준다. 여러 줄이면 세션 목록.
final class BubbleView: NSView {
    var lines: [String] = [] { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }


    override func draw(_ dirtyRect: NSRect) {
        guard !lines.isEmpty else { return }
        let text = lines.joined(separator: "\n")
        let para = NSMutableParagraphStyle(); para.alignment = lines.count > 1 ? .left : .center; para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.black, .paragraphStyle: para,
        ]
        let maxW = bounds.width - 16
        let size = (text as NSString).boundingRect(with: NSSize(width: maxW - 20, height: bounds.height - 24), options: [.usesLineFragmentOrigin], attributes: attrs).size
        let w = min(maxW, size.width + 24), h = min(bounds.height - 12, size.height + 14)
        let box = NSRect(x: (bounds.width - w) / 2, y: bounds.height - h - 16, width: w, height: h)
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
