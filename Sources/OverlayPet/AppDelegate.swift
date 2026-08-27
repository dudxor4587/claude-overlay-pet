import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: PetWindow!
    private var view: PetView!
    private var config = Config.load()
    private var watcher: Timer?
    private var lastStateTS: Double = 0
    private var lastFileMTime: Date?
    private var fetching = false
    private var focusSession: String?
    private static let passThrough: Set<String> = ["done", "error", "notify"]

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? Paths.ensureDirectories()
        NSApp.setActivationPolicy(.accessory)

        view = PetView(frame: .zero)
        view.configure(config: config)
        let size = CGSize(width: max(view.spriteSize.width, 260), height: view.spriteSize.height + PetView.bubbleHeight)
        let origin = config.position.map { NSPoint(x: $0.x, y: $0.y) } ?? defaultOrigin(size)
        window = PetWindow(contentRect: NSRect(origin: origin, size: size))
        window.contentView = view
        view.onMoved = { [weak self] p in
            guard let self else { return }
            self.config.position = .init(x: p.x, y: p.y)
            try? self.config.save()
        }
        view.onRightClick = { [weak self] e in self?.showMenu(e) }
        window.orderFrontRegardless()

        if config.activePet == nil || !Pets.installed().contains(config.activePet!) {
            config.activePet = DefaultPet.ensureInstalled()
            try? config.save()
        }
        loadActivePet()
        applyState(PetStateFile.read(), initial: true)
        watcher = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
        RunLoop.main.add(watcher!, forMode: .common)

        if config.activePet == DefaultPet.id {
            view.say("우클릭 → 캐릭터 가져오기", seconds: 8)
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
            let (_, sheet) = try SpriteSheet.load(petId: id)
            view.setSheet(sheet)
            resizeWindow()
        } catch {
            view.setSheet(nil)
            view.say("펫 로드 실패: \(error.localizedDescription)", seconds: 6)
        }
    }

    private func resizeWindow() {
        let size = CGSize(width: max(view.spriteSize.width, 260), height: view.spriteSize.height + PetView.bubbleHeight)
        var f = window.frame; f.size = size
        window.setFrame(f, display: true)
    }

    // MARK: 상태 파일 감시

    private func poll() {
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
            sessions[sid] = Session(cwd: s.cwd ?? "?", state: s.state, message: s.message, ts: s.ts)
        }
        // 포커스: 마지막으로 프롬프트를 친 세션. 애니메이션은 포커스 세션을 따라간다.
        if s.state == "prompt" || s.state == "start" || focusSession == nil { focusSession = sid }
        if sid == focusSession {
            view.play(state: s.state, force: !initial)
            if isNew, let name = config.effects[s.state], let e = try? Effect.load(name: name) { view.playEffect(e) }
        } else if isNew, Self.passThrough.contains(s.state) {
            view.playOnce(state: s.state)   // 다른 세션의 완료·실패·알림은 1회만
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
        try? PetStateFile(state: s, tool: nil, message: nil, cwd: nil, sessionId: nil, ts: Date().timeIntervalSince1970).write()
    }

    @objc private func openFolder() { NSWorkspace.shared.open(Paths.root) }

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
        guard alert.runModal() == .alertFirstButtonReturn else { return }
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
            } catch {
                self?.view.say("실패: \(error.localizedDescription)", seconds: 8)
            }
            self?.fetching = false
        }
    }
}
