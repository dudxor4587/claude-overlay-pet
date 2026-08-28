import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: PetWindow!
    private var view: PetView!
    private var config = Config.load()
    private var bindings = PetBindings()
    private var watcher: Timer?
    private var lastStateTS: Double = 0
    private var lastFileMTime: Date?
    private var fetching = false
    private var activeManifest: PetManifest?
    private var activePicker: SkillPicker?
    private var focusSession: String?
    private static let passThrough: Set<String> = ["done", "error", "notify"]

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? Paths.ensureDirectories()
        NSApp.setActivationPolicy(.accessory)

        view = PetView(frame: .zero)
        view.configure(config: config)
        let size = view.canvasSize
        if (config.canvasVersion ?? 1) < 2, var p = config.position {   // 캔버스가 넓어진 만큼 위치 보정
            p.x -= (PetView.canvasWidth - 260) / 2
            config.position = p; config.canvasVersion = 2; try? config.save()
        }
        let origin = config.position.map { NSPoint(x: $0.x, y: $0.y) } ?? defaultOrigin(size)
        window = PetWindow(contentRect: NSRect(origin: origin, size: size))
        window.contentView = view
        view.onMoved = { [weak self] p in
            guard let self else { return }
            self.config.position = .init(x: p.x, y: p.y)
            try? self.config.save()
        }
        view.onRightClick = { [weak self] e in self?.showMenu(e) }
        view.onHover = { [weak self] in
            guard let self, !["sleep", "end"].contains(self.view.currentState) else { return }
            self.view.playOnce(state: "notify")   // 손 흔들기
        }
        window.orderFrontRegardless()

        if config.activePet == nil || !Pets.installed().contains(config.activePet!) {
            config.activePet = DefaultPet.ensureInstalled()
            try? config.save()
        }
        PetBindings.migrateIfNeeded(config: &config)
        loadActivePet()
        applyState(PetStateFile.read(), initial: true)
        watcher = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
        RunLoop.main.add(watcher!, forMode: .common)

        if config.activePet == DefaultPet.id {
            view.say("우클릭 → 캐릭터 가져오기", seconds: 8)
        }
        refreshStaleNexonDataIfNeeded()
    }

    /// 메이플스토리 Open API 고지: 크롤링한 데이터는 30일 이내에 갱신해야 한다.
    /// 활성 펫의 넥슨 데이터가 30일을 넘겼으면 조용히 다시 받는다.
    /// 키가 없거나 한도(429)에 걸리면 이번엔 넘기고 다음 실행 때 다시 시도한다 —
    /// 막힌 서버를 계속 두드리지 않기 위해서다.
    private func refreshStaleNexonDataIfNeeded() {
        guard let id = config.activePet, id != DefaultPet.id,
              let m = activeManifest, m.isStale,
              let key = APIKey.resolve(), !key.isEmpty else { return }
        let name = m.displayName
        view.say("캐릭터 정보 갱신 중…", seconds: 4)
        Task.detached { [weak self] in
            do {
                _ = try await SheetBuilder.build(characterName: name, apiKey: key, weapon: false) { _ in }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.loadActivePet()
                    self.view.say("캐릭터 정보를 갱신했습니다", seconds: 4)
                }
            } catch {
                let msg = error.isRateLimited
                    ? "넥슨 API 호출 한도로 갱신을 미룹니다"
                    : "캐릭터 갱신 실패: \(error.localizedDescription)"
                await MainActor.run { [weak self] in self?.view.say(msg, seconds: 5) }
            }
        }
    }

    private func defaultOrigin(_ size: CGSize) -> NSPoint {
        let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        return NSPoint(x: vf.maxX - size.width - 24, y: vf.minY + 24)
    }

    // MARK: 펫 로드

    private func loadActivePet() {
        guard let id = config.activePet else { view.setSheet(nil); return }
        do {
            let (manifest, sheet) = try SpriteSheet.load(petId: id)
            activeManifest = manifest
            bindings = PetBindings.load(id)
            view.setSheet(sheet)
            resizeWindow()
        } catch {
            view.setSheet(nil)
            view.say("펫 로드 실패: \(error.localizedDescription)", seconds: 6)
        }
    }

    private func resizeWindow() {
        let size = view.canvasSize
        var f = window.frame; f.size = size
        window.setFrame(f, display: true)
    }

    // MARK: 상태 파일 감시

    private var lastConfigMTime: Date?
    private var lastGalleryAt: TimeInterval = 0
    private var galleryIndex = 0

    /// 갤러리: 고른 스킬들을 간격마다 돌아가며 재생 (다른 이펙트 재생 중이면 건너뜀)
    private func galleryTick() {
        let g = bindings.gallery
        guard !g.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        guard now - lastGalleryAt >= (config.galleryInterval ?? 30), !view.isPlayingEffects else { return }
        lastGalleryAt = now
        galleryIndex = (galleryIndex + 1) % g.count
        view.playEffects(effects(named: g[galleryIndex]))
    }

    private func poll() {
        galleryTick()
        // CLI(effect set 등)로 config.json 이 바뀌면 그대로 반영
        if let cm = (try? FileManager.default.attributesOfItem(atPath: Paths.config.path))?[.modificationDate] as? Date, cm != lastConfigMTime {
            if lastConfigMTime != nil { config = Config.load(); view.configure(config: config); bindings = PetBindings.load(config.activePet) }
            lastConfigMTime = cm
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: Paths.state.path)
        let mtime = attrs?[.modificationDate] as? Date
        if mtime != lastFileMTime {
            lastFileMTime = mtime
            applyState(PetStateFile.read(), initial: false)
        } else if !sessions.isEmpty, Int(Date().timeIntervalSince1970) % 10 == 0 {
            refreshStatus()
        } else if let s = PetStateFile.read(), view.currentState != "sleep", view.currentState != "end",
                  Date().timeIntervalSince1970 - s.ts > config.sleepAfterSeconds {
            view.play(state: "sleep")
        }
    }

    /// 프롬프트를 친 세션들을 추적해 말풍선에 목록으로 보여준다.
    private struct Session { var cwd: String; var state: String; var message: String?; var ts: Double }
    private var sessions: [String: Session] = [:]

    private func applyState(_ s: PetStateFile?, initial: Bool) {
        guard let s else { view.play(state: "idle"); return }
        let stale = Date().timeIntervalSince1970 - s.ts > config.sleepAfterSeconds
        if stale { view.play(state: s.state == "end" ? "end" : "sleep"); return }
        let isNew = !initial && s.ts != lastStateTS
        lastStateTS = s.ts

        guard let sid = s.sessionId else {
            // 세션 정보 없는 수동 이벤트 (state 커맨드 등)
            view.play(state: s.state, force: !initial)
            if isNew { view.say(s.message ?? AnimationMap.bubbleText[s.state] ?? s.state, seconds: config.bubbleSeconds) }
            return
        }

        // 세션 목록 갱신
        if s.state == "end" {
            sessions[sid] = nil
            if focusSession == sid { focusSession = nil }
        } else {
            sessions[sid] = Session(cwd: s.label, state: s.state, message: s.message, ts: s.ts)
        }
        // 포커스: 마지막으로 프롬프트를 친 세션. 애니메이션은 포커스 세션을 따라간다.
        if s.state == "prompt" || s.state == "start" || focusSession == nil { focusSession = sid }
        if sid == focusSession {
            view.play(state: s.state, force: !initial)
            if isNew { view.playEffects(effects(for: s.state)) }
        } else if isNew, Self.passThrough.contains(s.state) {
            view.playOnce(state: s.state)   // 다른 세션의 완료·실패·알림은 1회만
            view.playEffects(effects(for: s.state))
        }
        refreshStatus()
    }

    /// 말풍선 세션 패널. 오래된 세션은 빠진다.
    private func refreshStatus() {
        let now = Date().timeIntervalSince1970
        sessions = sessions.filter { now - $0.value.ts < config.sleepAfterSeconds }
        let lines = sessions.sorted { $0.value.ts > $1.value.ts }.prefix(4).map { sid, s -> String in
            let label = s.message ?? AnimationMap.bubbleText[s.state] ?? s.state
            return (sid == focusSession ? "▶ " : "· ") + s.cwd + " — " + label
        }
        view.setStatus(lines)
    }

    // MARK: 메뉴

    private func showMenu(_ event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: "캐릭터 가져오기…", action: #selector(fetchCharacter), keyEquivalent: "").target = self

        let pets = Pets.installed()
        if !pets.isEmpty {
            let sub = NSMenu()
            for p in pets {
                let it = NSMenuItem(title: p, action: #selector(selectPet(_:)), keyEquivalent: "")
                it.target = self; it.representedObject = p
                it.state = p == config.activePet ? .on : .off
                sub.addItem(it)
            }
            let item = NSMenuItem(title: "펫 선택", action: nil, keyEquivalent: "")
            item.submenu = sub
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "직업 스킬 이펙트 받기…", action: #selector(fetchEffect), keyEquivalent: "").target = self
        let infos = EffectInfo.all()
        if !infos.isEmpty {
            // 상태 → 차수 → 스킬 → (변형) 로 묶는다
            let assign = NSMenu()
            for state in Self.effectStates {
                let sub = NSMenu()
                let none = NSMenuItem(title: "없음", action: #selector(assignEffect(_:)), keyEquivalent: "")
                none.target = self; none.representedObject = [state, ""]
                none.state = bindings.effects[state] == nil ? .on : .off
                sub.addItem(none)
                sub.addItem(.separator())
                for item in tierMenus(infos, action: #selector(assignEffect(_:)), tag: state) { sub.addItem(item) }
                let item = NSMenuItem(title: "\(state) — \(AnimationMap.bubbleText[state] ?? state)", action: nil, keyEquivalent: "")
                if let cur = bindings.effects[state], let first = cur.split(separator: ",").first,
                   let info = infos.first(where: { $0.name == String(first) }) {
                    item.title += "   [\(info.skillTitle)]"
                }
                item.submenu = sub
                assign.addItem(item)
            }
            let assignItem = NSMenuItem(title: "상태별 이펙트", action: nil, keyEquivalent: "")
            assignItem.submenu = assign
            menu.addItem(assignItem)

            let play = NSMenu()
            for item in tierMenus(infos, action: #selector(testEffect(_:)), tag: nil) { play.addItem(item) }
            let playItem = NSMenuItem(title: "이펙트 재생", action: nil, keyEquivalent: "")
            playItem.submenu = play
            menu.addItem(playItem)

            // 갤러리: 체크한 스킬을 주기적으로 돌아가며 재생
            let gal = NSMenu()
            let interval = NSMenu()
            for sec in [5.0, 15.0, 30.0, 60.0, 120.0, 300.0] {
                let it = NSMenuItem(title: sec < 60 ? "\(Int(sec))초" : "\(Int(sec / 60))분", action: #selector(setGalleryInterval(_:)), keyEquivalent: "")
                it.target = self; it.representedObject = sec
                it.state = (config.galleryInterval ?? 30) == sec ? .on : .off
                interval.addItem(it)
            }
            let intervalItem = NSMenuItem(title: "재생 간격", action: nil, keyEquivalent: "")
            intervalItem.submenu = interval
            gal.addItem(intervalItem)
            let all = NSMenuItem(title: "모두 선택", action: #selector(selectAllGallery), keyEquivalent: "")
            all.target = self; gal.addItem(all)
            let clear = NSMenuItem(title: "모두 해제", action: #selector(clearGallery), keyEquivalent: "")
            clear.target = self; gal.addItem(clear)
            gal.addItem(.separator())
            for item in tierMenus(infos, action: #selector(toggleGallery(_:)), tag: "gallery") { gal.addItem(item) }
            let n = bindings.gallery.count
            let galItem = NSMenuItem(title: "갤러리 (주기 재생)" + (n > 0 ? " · \(n)개" : ""), action: nil, keyEquivalent: "")
            galItem.submenu = gal
            menu.addItem(galItem)

            let op = NSMenu()
            for v in [1.0, 0.8, 0.6, 0.4, 0.25] {
                let it = NSMenuItem(title: "\(Int(v * 100))%", action: #selector(setEffectOpacity(_:)), keyEquivalent: "")
                it.target = self; it.representedObject = v
                it.state = (config.effectOpacity ?? 1) == v ? .on : .off
                op.addItem(it)
            }
            let opItem = NSMenuItem(title: "이펙트 투명도", action: nil, keyEquivalent: "")
            opItem.submenu = op
            menu.addItem(opItem)
        }

        menu.addItem(.separator())
        let hooks = NSMenuItem(title: Hooks.isInstalled() ? "Claude Code 훅 제거" : "Claude Code 훅 설치",
                               action: #selector(toggleHooks), keyEquivalent: "")
        hooks.target = self
        menu.addItem(hooks)

        let login = NSMenuItem(title: "로그인 시 실행", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.isEnabled = Bundle.main.bundleIdentifier != nil
        menu.addItem(login)

        let test = NSMenuItem(title: "상태 테스트", action: nil, keyEquivalent: "")
        let tsub = NSMenu()
        for s in ["start", "prompt", "bash", "edit", "notify", "error", "done", "end", "sleep", "idle"] {
            let it = NSMenuItem(title: s, action: #selector(testState(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = s; tsub.addItem(it)
        }
        test.submenu = tsub
        menu.addItem(test)

        menu.addItem(withTitle: "데이터 폴더 열기", action: #selector(openFolder), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "종료", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q")
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    @objc private func selectPet(_ sender: NSMenuItem) {
        config.activePet = sender.representedObject as? String
        try? config.save()
        loadActivePet()
    }

    @objc private func toggleHooks() {
        do {
            if Hooks.isInstalled() { try Hooks.uninstall(); view.say("훅 제거됨", seconds: 3) }
            else { try Hooks.install(); view.say("훅 설치됨 (Claude Code 재시작)", seconds: 5) }
        } catch { view.say("훅 변경 실패: \(error.localizedDescription)", seconds: 6) }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { view.say("로그인 항목 변경 실패: \(error.localizedDescription)", seconds: 6) }
    }

    @objc private func testState(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String else { return }
        try? PetStateFile(state: s, tool: nil, message: nil, cwd: nil, name: nil, sessionId: nil, ts: Date().timeIntervalSince1970).write()
    }

    @objc private func openFolder() { NSWorkspace.shared.open(Paths.root) }

    // MARK: 이펙트

    /// 차수 → 스킬 2단 메뉴. 스킬을 고르면 조각 전부(소환수 제외)를 게임 순서로 재생한다.
    /// tag 가 있으면 representedObject = [tag, "a,b,c"], 없으면 "a,b,c".
    private func tierMenus(_ infos: [EffectInfo], action: Selector, tag: String?) -> [NSMenuItem] {
        let byTier = Dictionary(grouping: infos, by: { $0.tier })
        let assigned = bindings.effects
        return byTier.keys.sorted { (byTier[$0]!.first!.tierOrder, $0) < (byTier[$1]!.first!.tierOrder, $1) }.map { tier in
            let tierMenu = NSMenu()
            let bySkill = Dictionary(grouping: byTier[tier]!, by: { $0.skillTitle })
            for skill in bySkill.keys.sorted() {
                // 타격 조각은 제외 (몬스터 자리 기준이라 캐릭터에 맞출 수 없다)
                let usable = bySkill[skill]!.filter {
                    let v = $0.variant.lowercased()
                    // 소환수(stand)는 이제 제대로 가져오므로 빼지 않는다 — 어느 항목에 붙일지는 forms 가 정한다
                    return !v.contains("summon") && !v.hasPrefix("타격") && !v.hasPrefix("몹") && !v.hasPrefix("피격")
                }
                // 이름이 같아도 게임에서 서로 대체되는 형태면 (데몬 베인: 일반 / 각성) 항목을 나눈다.
                let forms = EffectSequencer.forms(usable)
                for (i, form) in forms.enumerated() {
                    let pieces = form.pieces.map(\.name).sorted()
                    guard !pieces.isEmpty else { continue }
                    let value = pieces.joined(separator: ",")
                    let it = NSMenuItem(title: forms.count > 1 ? "\(skill) \(Self.formMark(i))" : skill,
                                        action: action, keyEquivalent: "")
                    it.target = self
                    // 형태가 갈린 항목은 어느 쪽인지 이름만으론 모른다 — 넥슨이 쓴 스킬 설명을 그대로 보여준다.
                    if forms.count > 1 {
                        let d = form.pieces.first?.manifest.desc?.replacingOccurrences(of: "\\n", with: "\n")
                        it.toolTip = [d, "스킬 ID \(form.id)"].compactMap { $0 }.joined(separator: "\n\n")
                    }
                    it.representedObject = tag.map { [$0, value] as Any } ?? value
                    if tag == "gallery" {
                        if bindings.gallery.contains(value) { it.state = .on }
                    } else if let tag, let cur = assigned[tag], Set(cur.split(separator: ",").map(String.init)).isSubset(of: Set(pieces)) { it.state = .on }
                    tierMenu.addItem(it)
                }
            }
            let it = NSMenuItem(title: "\(tier) (\(bySkill.count))", action: nil, keyEquivalent: "")
            it.submenu = tierMenu
            return it
        }
    }

    /// 대체 형태가 여럿인 스킬의 항목 구분 표시 (①②③…)
    private static func formMark(_ i: Int) -> String {
        let marks = ["①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧", "⑨"]
        return i < marks.count ? marks[i] : "(\(i + 1))"
    }

    static let effectStates = ["start", "prompt", "bash", "edit", "notify", "error", "done", "end"]

    /// bindings.effects 값은 "a,b,c" 처럼 여러 변형을 쉼표로 이을 수 있다 (스킬 전체 = Effect+Hit+…)
    private func effects(for state: String) -> [Effect] {
        (bindings.effects[state] ?? "").split(separator: ",").compactMap { try? Effect.load(name: String($0).trimmingCharacters(in: .whitespaces)) }
    }
    private func effects(named value: String) -> [Effect] {
        value.split(separator: ",").compactMap { try? Effect.load(name: String($0)) }
    }

    @objc private func assignEffect(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2 else { return }
        bindings.effects[pair[0]] = pair[1].isEmpty ? nil : pair[1]
        try? bindings.save(config.activePet)
        if !pair[1].isEmpty { view.playEffects(effects(named: pair[1])) }
    }

    @objc private func toggleGallery(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2 else { return }
        var g = bindings.gallery
        if let i = g.firstIndex(of: pair[1]) { g.remove(at: i) } else { g.append(pair[1]); view.playEffects(effects(named: pair[1])) }
        bindings.gallery = g
        try? bindings.save(config.activePet)
    }

    @objc private func clearGallery() { bindings.gallery = []; try? bindings.save(config.activePet) }

    /// 설치된 스킬 전부를 갤러리에 (형태가 갈린 스킬은 형태마다 한 항목)
    @objc private func selectAllGallery() {
        let bySkill = Dictionary(grouping: EffectInfo.all(), by: { "\($0.tierOrder)|\($0.skillTitle)" })
        bindings.gallery = bySkill.keys.sorted().flatMap { key -> [String] in
            let usable = bySkill[key]!.filter {
                let v = $0.variant.lowercased()
                // 소환수(stand)는 이제 제대로 가져오므로 빼지 않는다 — 어느 항목에 붙일지는 forms 가 정한다
                return !v.contains("summon") && !v.hasPrefix("타격") && !v.hasPrefix("몹") && !v.hasPrefix("피격")
            }
            return EffectSequencer.forms(usable).compactMap { form in
                let pieces = form.pieces.map(\.name).sorted()
                return pieces.isEmpty ? nil : pieces.joined(separator: ",")
            }
        }
        try? bindings.save(config.activePet)
    }

    @objc private func setEffectOpacity(_ sender: NSMenuItem) {
        config.effectOpacity = sender.representedObject as? Double
        try? config.save()
        view.configure(config: config)
    }

    @objc private func setGalleryInterval(_ sender: NSMenuItem) {
        config.galleryInterval = sender.representedObject as? Double
        try? config.save()
    }

    @objc private func testEffect(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        view.playEffects(effects(named: value))
    }

    /// 활성 펫의 직업 스킬 이펙트를 (다시) 받는다. 캐릭터 가져오기 때 자동으로도 호출.
    @objc private func fetchEffect() {
        if fetching { view.say("이미 받는 중이야 (잠시 후 다시)", seconds: 4); return }
        guard let job = activeManifest?.jobName else { view.say("직업 정보가 없는 펫이야", seconds: 4); return }
        fetching = true
        Task { [weak self] in
            defer { self?.fetching = false }
            await self?.importJobSkills(job)
        }
    }

    private func importJobSkills(_ job: String) async {
        view.say("\(job) 스킬 목록 불러오는 중…", seconds: 60)
        let skills: [MapleWZ.Skill]
        do {
            skills = try await SkillCatalog.load(petId: config.activePet, job: job) { [weak self] msg in
                Task { @MainActor in self?.view.say(msg, seconds: 60) }
            }
        } catch {
            view.say("스킬 가져오기 실패: \(error.localizedDescription)", seconds: 8); return
        }
        guard !skills.isEmpty else { view.say("\(job) 스킬을 찾지 못했어", seconds: 5); return }
        view.say("\(skills.count)개 스킬 — 받을 스킬을 골라 줘", seconds: 30)
        let picker = SkillPicker(skills: skills)
        activePicker = picker                       // 대화상자가 살아 있는 동안 유지
        defer { activePicker = nil }
        view.forcePassThrough = true
        let picked = picker.run(title: "\(job) 스킬 이펙트")
        view.forcePassThrough = false
        guard let picked, !picked.isEmpty else { view.say("취소", seconds: 2); return }
        view.say("\(picked.count)개 스킬 받는 중…", seconds: 60)
        let names = await SkillCatalog.install(picked: picked, petId: config.activePet, job: job) { [weak self] msg in
            Task { @MainActor in self?.view.say(msg, seconds: 60) }
        }
        // 메뉴는 스킬 단위로 묶어 보여주므로 조각 수가 아니라 스킬 수를 알려준다
        let skillCount = Set(EffectInfo.all().filter { names.contains($0.name) }.map(\.skillTitle)).count
        view.say("스킬 \(skillCount)개 준비 완료 · 우클릭 → 상태별 이펙트", seconds: 8)
    }


    // MARK: 캐릭터 가져오기 (앱 내장 fetcher)

    @objc private func fetchCharacter() {
        guard !fetching else { return }
        let alert = NSAlert()
        alert.messageText = "캐릭터 가져오기"
        alert.informativeText = "넥슨 Open API 키와 캐릭터명을 입력하면 공식 이미지로 스프라이트 시트를 만듭니다.\n키 발급: https://openapi.nexon.com"
        alert.addButton(withTitle: "가져오기")
        alert.addButton(withTitle: "취소")

        let box = NSStackView(frame: NSRect(x: 0, y: 0, width: 340, height: 84))
        box.orientation = .vertical; box.spacing = 8; box.alignment = .leading
        let key = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        key.placeholderString = "NEXON Open API 키 (.env 의 NEXON_API_KEY 자동 사용)"
        key.stringValue = APIKey.resolve() ?? ""
        let name = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        name.placeholderString = "캐릭터명"
        let weapon = NSButton(checkboxWithTitle: "무기 포함", target: nil, action: nil)
        for v in [key, name] { v.widthAnchor.constraint(equalToConstant: 340).isActive = true }
        box.addArrangedSubview(key); box.addArrangedSubview(name); box.addArrangedSubview(weapon)
        alert.accessoryView = box
        alert.window.initialFirstResponder = key.stringValue.isEmpty ? key : name

        NSApp.activate(ignoringOtherApps: true)
        view.forcePassThrough = true
        let response = alert.runModal()
        view.forcePassThrough = false
        guard response == .alertFirstButtonReturn else { return }
        let apiKey = key.stringValue.trimmingCharacters(in: .whitespaces)
        let charName = name.stringValue.trimmingCharacters(in: .whitespaces)
        guard !apiKey.isEmpty, !charName.isEmpty else { view.say("키와 캐릭터명을 모두 입력해 줘", seconds: 4); return }
        config.nexonApiKey = apiKey
        try? config.save()

        fetching = true
        Task { [weak self] in
            do {
                let id = try await SheetBuilder.build(characterName: charName, apiKey: apiKey, weapon: weapon.state == .on) { msg in
                    Task { @MainActor in self?.view.say(msg, seconds: 30) }
                }
                self?.config.activePet = id
                try? self?.config.save()
                self?.loadActivePet()
                self?.view.say("\(charName) 등장!", seconds: 4)
                self?.view.play(state: "start", force: true)
                if let job = self?.activeManifest?.jobName { await self?.importJobSkills(job) }
            } catch {
                self?.view.say("실패: \(error.localizedDescription)", seconds: 8)
            }
            self?.fetching = false
        }
    }
}
