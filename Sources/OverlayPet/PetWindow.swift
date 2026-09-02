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
        acceptsMouseMovedEvents = true   // 클릭 통과 판정이 mouseMoved 를 받아야 한다
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
    private var effectOpacity: Float = 1

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
        var loops: Int          // 남은 반복 횟수 (키다운 루프)
        var timer: Timer?
        init(_ e: Effect, offsetX: CGFloat, loops: Int) { effect = e; self.offsetX = offsetX; self.loops = loops }
        deinit { timer?.invalidate(); layer.removeFromSuperlayer() }
    }
    private var players: [EffectPlayer] = []
    private var scheduled: [DispatchWorkItem] = []

    private var dragOffset: NSPoint?
    var onMoved: ((NSPoint) -> Void)?
    var onRightClick: ((NSEvent) -> Void)?

    // 레이아웃: 창을 스프라이트보다 넉넉히 잡아 큰 이펙트가 잘리지 않게 한다. 투명 영역은 클릭 통과.
    static let bubbleHeight: CGFloat = 110   // 세션 4줄까지
    static let canvasWidth: CGFloat = 900
    static let canvasTopPad: CGFloat = 420   // 스프라이트 위 이펙트 여유
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

    /// 트래킹 영역이 있어야 커서가 창 위에 있을 때 mouseMoved 가 돈다 — 클릭 통과 판정이 여기 기댄다.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    /// 다이얼로그가 떠 있는 동안에는 무조건 통과시킨다.
    /// 펫 창은 .floating(3) 이라 NSAlert(레벨 0) 보다 위에 있어서, 겹친 자리의 클릭·휠을 펫 창이 먹어 버린다.
    var forcePassThrough = false { didSet { updatePassThrough() } }

    /// 창 단위 클릭 통과. 뷰의 hitTest 만으로는 이펙트가 그려진 영역에서 macOS 가 창에 이벤트를 넘겨 버리므로,
    /// 커서가 캐릭터·말풍선 위에 있을 때만 창이 마우스를 받고 나머지는 항상 아래 창으로 통과시킨다.
    private var mouseMonitors: [Any] = []
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        mouseMonitors.forEach(NSEvent.removeMonitor)
        mouseMonitors = []
        guard window != nil else { return }
        // 전역 모니터는 시스템 전체 이벤트를 거쳐가므로 종류를 늘리지 않는다.
        // AppKit 의 스크롤 모니터와 같은 레지스트리 락을 쓰기 때문에 휠까지 걸면 스크롤이 느려진다.
        let handler: (NSEvent) -> Void = { [weak self] _ in self?.updatePassThrough() }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: handler) { mouseMonitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { e in handler(e); return e }) { mouseMonitors.append(l) }
        updatePassThrough()
    }
    func updatePassThrough() {
        guard let w = window, dragOffset == nil else { return }
        var over = false
        if !forcePassThrough {
            let p = convert(w.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            over = hitTest(convert(p, to: superview)) != nil
        }
        if w.ignoresMouseEvents == over { w.ignoresMouseEvents = !over }
    }

    /// 이펙트가 재생 중이거나 예약돼 있으면 true (갤러리가 겹치지 않게)
    var isPlayingEffects: Bool { !players.isEmpty || pendingCount > 0 }
    private var pendingCount = 0

    func configure(config: Config) {
        scale = CGFloat(config.scale)
        baseFPS = config.fps
        effectOpacity = Float(config.effectOpacity ?? 1)
        players.forEach { $0.layer.opacity = effectOpacity }
        animSpecs = AnimationMap.resolve(config)
        needsLayout = true
    }

    /// 행마다 "머리 꼭대기까지의 셀 안 여백"(픽셀). 말풍선을 머리 바로 위에 붙이기 위해 쓴다.
    /// 상태별로 다른 GIF 를 넣은 커스텀 펫은 행마다 키가 크게 달라서, 한 행만 재면 말풍선이 어긋난다.
    private var headInsets: [CGFloat] = []
    /// 지금 재생 중인 행의 여백
    private var headInset: CGFloat {
        headInsets.indices.contains(spec.row) ? headInsets[spec.row] : (headInsets.first ?? 0)
    }

    func setSheet(_ sheet: SpriteSheet?, custom: Bool = false) {
        self.sheet = sheet
        customSheet = custom
        alpha = sheet.flatMap { Raster.alphaMask($0.image) }
        spriteLayer.contents = sheet?.image
        measureRowInsets()
        needsLayout = true
        play(state: currentState, force: true)
    }

    /// 행마다 말풍선을 붙일 가로 중심.
    /// 메이플 펫은 발 기준 하나로 — 무기·망토가 옆으로 뻗어도 발은 몸 중심에 가깝다.
    /// 커스텀 펫은 그 행 그림의 가로 중심 — 사진·GIF 에는 "발" 이라는 개념이 없다.
    private var headCenters: [CGFloat] = []
    private var headCenterX: CGFloat {
        headCenters.indices.contains(spec.row) ? headCenters[spec.row]
            : (headCenters.first ?? CGFloat(sheet?.frameWidth ?? 192) / 2)
    }
    /// 커스텀 펫(사진·GIF)인지 — 가로 중심 기준이 달라진다
    private var customSheet = false

    /// 발 위치(셀 안 y)와 몸통 가로 중심 — 이펙트 정렬용
    private var footY: CGFloat = 188
    private var bodyCenterX: CGFloat = 96

    private func measureRowInsets() {
        guard let s = sheet, let a = alpha else { headInsets = []; return }
        let w = s.image.width
        var top: Int?, bottom = 0
        var rowMin = [Int](repeating: Int.max, count: s.frameHeight), rowMax = [Int](repeating: -1, count: s.frameHeight)
        for y in 0..<s.frameHeight {
            let rowBase = y * w
            for x in 0..<s.frameWidth where x < w && a[rowBase + x] > 8 {   // 0행 0열 프레임만
                if top == nil { top = y }
                rowMin[y] = min(rowMin[y], x); rowMax[y] = max(rowMax[y], x)
                bottom = y
            }
        }
        // 가로 중심은 발 부분(맨 아래 24px 행)의 픽셀 범위로 잡는다. 게임의 기준점도 발밑이고,
        // 무기·망토처럼 한쪽으로 길게 뻗은 장비는 대개 바닥까지 안 내려와서 몸 중심에 가깝다.
        var fl = Int.max, fr = -1
        for y in max(0, bottom - 24)...max(0, bottom) where rowMax[y] >= 0 { fl = min(fl, rowMin[y]); fr = max(fr, rowMax[y]) }
        let center = fr >= 0 ? CGFloat(fl + fr) / 2 : CGFloat(s.frameWidth) / 2
        bodyCenterX = center
        footY = CGFloat(bottom + 1)

        // 행마다 그 행의 모든 프레임을 훑어 가장 높은 지점을 찾는다.
        // 프레임 0 만 재면 더 높이 올라가는 프레임이 말풍선을 뚫는다.
        func topOfRow(_ r: Int) -> CGFloat {
            let cols = max(1, r < s.frameCounts.count ? s.frameCounts[r] : 1)
            let strip = min(w, s.frameWidth * cols)
            for y in 0..<s.frameHeight {
                let base = (r * s.frameHeight + y) * w
                for x in 0..<strip where base + x < a.count && a[base + x] > 8 { return CGFloat(y) }
            }
            return CGFloat(s.frameHeight)
        }
        headInsets = (0..<s.rows).map(topOfRow)

        // 커스텀 펫은 행마다 그림이 달라 가로 중심도 행별로 잡는다.
        // 한 행의 모든 프레임을 셀 안 좌표로 합쳐, 움직임까지 아우르는 가운데를 쓴다.
        func centerOfRow(_ r: Int) -> CGFloat {
            let cols = max(1, r < s.frameCounts.count ? s.frameCounts[r] : 1)
            var left = Int.max, right = -1
            for y in 0..<s.frameHeight {
                let rowBase = (r * s.frameHeight + y) * w
                for c in 0..<cols {
                    let x0 = c * s.frameWidth
                    for x in 0..<s.frameWidth where x0 + x < w && a[rowBase + x0 + x] > 8 {
                        if x < left { left = x }
                        if x > right { right = x }
                    }
                }
            }
            return right >= left ? CGFloat(left + right) / 2 : CGFloat(s.frameWidth) / 2
        }
        headCenters = (0..<s.rows).map { customSheet ? centerOfRow($0) : center }
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
    private var previousRow = -1

    func play(state: String, force: Bool = false, once: Bool? = nil, then: String? = nil) {
        guard force || state != currentState else { return }
        if once == nil { interruptedState = nil }
        currentState = state
        spec = animSpecs[state] ?? animSpecs["idle"] ?? AnimationSpec(row: 0)
        if let once { spec.once = once; spec.then = then }
        if let s = sheet, spec.row >= s.rows { spec.row = 0 }
        if spec.row != previousRow { previousRow = spec.row; needsLayout = true }   // 행마다 머리 높이가 달라 말풍선을 다시 앉힌다
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
            // 조각을 차례가 왔을 때 만들면 첫 프레임에서 시트(수 MB)를 GPU 로 올리느라 한 번 걸린다.
            // 레이어·이미지는 지금 다 올려 두고, 차례가 오면 숨김만 푼다.
            let p = EffectPlayer(item.effect, offsetX: CGFloat(item.offsetX), loops: item.loops)
            p.layer.magnificationFilter = .nearest
            p.layer.contentsGravity = .resize
            p.layer.actions = spriteLayer.actions
            p.layer.contents = item.effect.image
            p.layer.opacity = effectOpacity
            p.layer.contentsRect = item.effect.contentsRect(frame: 0)
            p.layer.isHidden = true
            layer?.addSublayer(p.layer)
            players.append(p)
            if item.delay <= 0 { begin(p); continue }
            let w = DispatchWorkItem { [weak self, weak p] in
                self?.pendingCount -= 1
                if let p { self?.begin(p) }
            }
            scheduled.append(w); pendingCount += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + item.delay, execute: w)
        }
        layoutEffect()
    }

    private func begin(_ p: EffectPlayer) {
        guard players.contains(where: { $0 === p }) else { return }
        p.layer.isHidden = false
        scheduleNextFrame(p)
    }

    /// WZ 의 프레임별 delay(ms)를 그대로 쓴다. 없으면 fps 로 균등.
    private func scheduleNextFrame(_ p: EffectPlayer) {
        let m = p.effect.manifest
        let interval: TimeInterval
        if let d = m.delays, p.frame < d.count { interval = Double(d[p.frame]) / 1000 }
        else { interval = 1 / max(1, m.fps) }
        p.timer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: max(0.016, interval), repeats: false) { [weak self, weak p] _ in
            guard let self, let p else { return }
            p.frame += 1
            if p.frame >= m.frames {
                p.loops -= 1
                if p.loops > 0 || m.loop { p.frame = 0 }
                else { self.players.removeAll { $0 === p }; return }
            }
            p.layer.contentsRect = p.effect.contentsRect(frame: p.frame)
            self.scheduleNextFrame(p)
        }
        p.timer = t
        RunLoop.main.add(t, forMode: .common)
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
            if let ax = m.anchorX, let ay = m.anchorY {
                // WZ origin 기준: 기준점이 캐릭터 발밑 중앙에 오도록
                let k = w / max(1, CGFloat(m.frameWidth) * scale * CGFloat(m.scale))   // 창 맞춤 축소 반영
                p.layer.frame = CGRect(x: cx - CGFloat(ax) * scale * CGFloat(m.scale) * k,
                                       y: feet - CGFloat(ay) * scale * CGFloat(m.scale) * k - CGFloat(m.offsetY) * scale,
                                       width: w, height: h)
            } else {
                let y: CGFloat = m.anchor == "bottom" ? feet - h : (sp.minY + headInset * scale + feet) / 2 - h / 2
                p.layer.frame = CGRect(x: cx - w / 2, y: y - CGFloat(m.offsetY) * scale, width: w, height: h)
            }
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
        // 말풍선은 실제로 그려진 박스만 클릭을 잡는다 (프레임 전체를 잡으면 화면 한 줄이 먹통이 된다)
        if !bubble.isHidden {
            let box = bubble.convert(bubble.drawnBox, to: self)
            if box.contains(p) { return self }
        }
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
    /// 마지막으로 그린 말풍선 박스 (클릭 판정용)
    private(set) var drawnBox: NSRect = .zero
    override var isFlipped: Bool { true }


    override func draw(_ dirtyRect: NSRect) {
        guard !lines.isEmpty else { drawnBox = .zero; return }
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
        drawnBox = box
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
