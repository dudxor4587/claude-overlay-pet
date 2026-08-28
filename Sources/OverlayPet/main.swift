import AppKit

@main
enum Main {
    static func main() {
        setlinebuf(stdout)   // 파이프로 넘겨도 진행 줄이 바로 나오게
        let args = Array(CommandLine.arguments.dropFirst())
        switch args.first {
        case nil, "run":
            runApp()
        case "hook":
            // 훅에서 호출: `OverlayPet hook <state>` — stdin 의 JSON 을 읽어 state.json 에 쓴다.
            guard args.count >= 2 else { fail("usage: hook <state>") }
            Hooks.handleEvent(state: args[1])
        case "hooks":
            switch args.dropFirst().first {
            case "install":
                attempt { try Hooks.install() }
                print("훅 설치됨 → \(Paths.claudeSettings.path)\nClaude Code 를 재시작하면 적용됩니다.")
            case "uninstall":
                attempt { try Hooks.uninstall() }
                print("훅 제거됨")
            case "status", nil:
                print(Hooks.isInstalled() ? "설치됨 (\(Hooks.binaryPath))" : "설치 안 됨")
            default: fail("usage: hooks install|uninstall|status")
            }
        case "fetch":
            // fetch <캐릭터명> [--api-key KEY] [--weapon] [--use]
            var name: String?, weapon = false, use = true
            var apiKey = APIKey.resolve()
            var it = args.dropFirst().makeIterator()
            while let a = it.next() {
                switch a {
                case "--api-key": apiKey = it.next()
                case "--weapon": weapon = true
                case "--no-use": use = false
                default: name = a
                }
            }
            guard let name, let apiKey, !apiKey.isEmpty else {
                fail("usage: fetch <캐릭터명> [--api-key KEY] [--weapon] [--no-use]\n(키는 config.json 의 nexonApiKey 에 저장됩니다)")
            }
            let sem = DispatchSemaphore(value: 0)
            var result: Result<String, Error>!
            Task.detached {
                do { result = .success(try await SheetBuilder.build(characterName: name, apiKey: apiKey, weapon: weapon) { print($0) }) }
                catch { result = .failure(error) }
                sem.signal()
            }
            sem.wait()
            switch result! {
            case .success(let id):
                var cfg = Config.load()
                cfg.nexonApiKey = apiKey
                if use { cfg.activePet = id }
                attempt { try cfg.save() }
                print("→ \(Paths.petDirectory(id).path)")
            case .failure(let e): fail(e.localizedDescription)
            }
        case "pets":
            let active = Config.load().activePet
            for p in Pets.installed() { print((p == active ? "* " : "  ") + p) }
        case "use":
            guard let id = args.dropFirst().first, Pets.installed().contains(id) else { fail("usage: use <petId>  (pets 로 목록 확인)") }
            var cfg = Config.load(); cfg.activePet = id
            attempt { try cfg.save() }
            print("활성 펫: \(id)")
        case "default":
            // 기본 펫(코드로 그린 고양이) 재생성 + 선택
            attempt { try DefaultPet.generate(into: Paths.petDirectory(DefaultPet.id)) }
            var cfg = Config.load(); cfg.activePet = DefaultPet.id
            attempt { try cfg.save() }
            print("기본 펫 생성: \(Paths.petDirectory(DefaultPet.id).path)")
        case "effects", "effect":
            // effect list | effect fetch [--tiers …|--all|--skill 이름] [--state S] | effect set <state> <name|none>
            let sub = Array(args.dropFirst())
            switch sub.first {
            case nil, "list":
                let list = Effect.installed(), b = PetBindings.load(Config.load().activePet)
                if list.isEmpty { print("설치된 이펙트 없음. effect fetch 로 가져오세요.") }
                for e in list {
                    let states = b.effects.filter { $0.value.split(separator: ",").contains(Substring(e)) }.map(\.key).sorted().joined(separator: ",")
                    print(states.isEmpty ? "  \(e)" : "  \(e)  ← \(states)")
                }
            case "fetch":
                var skill: String?, state: String?, all = false, tiers: Set<String>?
                var it = sub.dropFirst().makeIterator()
                while let a = it.next() {
                    switch a {
                    case "--skill": skill = it.next()
                    case "--state": state = it.next()
                    case "--pet": Paths.overridePet = it.next()   // 활성 펫 대신 이 펫 기준
                    case "--all": all = true
                    case "--tiers": tiers = it.next().map(parseTiers)
                    default: break
                    }
                }
                let petId = Paths.overridePet ?? Config.load().activePet
                guard let id = petId, let m = try? PetManifest.load(petId: id), let jobName = m.jobName else {
                    fail("활성 펫에 직업 정보가 없습니다.")
                }
                let sem = DispatchSemaphore(value: 0)
                var result: Result<String?, Error>!
                Task.detached {
                    do {
                        let skills = try await SkillCatalog.load(petId: id, job: jobName) { print($0) }
                        if all || tiers != nil {
                            let picked = tiers.map { t in skills.filter { t.contains($0.tier) } } ?? skills
                            let names = await SkillCatalog.install(picked: picked, petId: id, job: jobName) { print($0) }
                            print("\(names.count)개 설치 → \(Paths.effects.path)")
                            result = .success(nil); sem.signal(); return
                        }
                        guard let skill else {
                            var lastTier = "", seen = Set<String>()
                            for s in skills {
                                if s.tier != lastTier { lastTier = s.tier; seen = []; print("[\(s.tier)]") }
                                if seen.insert(s.name).inserted { print("  \(s.name)") }
                            }
                            result = .success(nil); sem.signal(); return
                        }
                        let picked = skills.filter { $0.name.contains(skill) }
                        guard !picked.isEmpty else { throw PetError("스킬을 찾을 수 없음: \(skill). effect fetch 로 목록 확인") }
                        let names = await SkillCatalog.install(picked: picked, petId: id, job: jobName) { print($0) }
                        print("\(names.count)개 조각 설치")
                        result = .success(names.first)
                    } catch { result = .failure(error) }
                    sem.signal()
                }
                sem.wait()
                switch result! {
                case .success(let name?):
                    print("→ \(Paths.effectDirectory(name).path)")
                    if let state {
                        let pet = Config.load().activePet
                        var b = PetBindings.load(pet); b.effects[state] = name
                        attempt { try b.save(pet) }
                        print("\(state) → \(name)")
                    }
                case .success(nil): break
                case .failure(let e): fail(e.localizedDescription)
                }
            case "set":
                guard sub.count >= 3 else { fail("usage: effect set <state> <name[,name…]|none>") }
                let pet = Config.load().activePet
                var b = PetBindings.load(pet)
                if sub[2] == "none" { b.effects[sub[1]] = nil }
                else {
                    // "a,b,c" 로 여러 조각을 순서 재생
                    let names = sub[2].split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                    let installed = Effect.installed()
                    for n in names where !installed.contains(n) { fail("설치되지 않은 이펙트: \(n)") }
                    b.effects[sub[1]] = names.joined(separator: ",")
                }
                attempt { try b.save(pet) }
                print("\(sub[1]) → \(sub[2])")
            default: fail("usage: effect list | fetch [URL] [--tiers 4,5,hyper | --skill NAME] [--state S] | set <state> <name|none>")
            }
        case "state":
            // 디버그: state <name> [message]
            guard args.count >= 2 else { fail("usage: state <name> [message]") }
            attempt { try PetStateFile(state: args[1], tool: nil, message: args.count > 2 ? args[2...].joined(separator: " ") : nil,
                                       cwd: nil, name: nil, sessionId: nil, ts: Date().timeIntervalSince1970).write() }
        default:
            print("""
            OverlayPet — Claude Code 상태를 보여주는 데스크톱 펫

              run                       오버레이 실행 (기본)
              fetch <캐릭터명> [--api-key K] [--weapon]   넥슨 API 로 스프라이트 시트 생성·설치
              pets | use <id>           설치된 펫 목록 / 선택
              hooks install|uninstall|status             Claude Code 훅 설정
              effect list               설치된 이펙트 목록
              effect fetch [--tiers 4,5,hyper | --all | --skill 이름] [--state S]   KMS 스킬 이펙트 가져오기
              effect set <state> <name|none>              상태에 이펙트 연결
              state <name> [msg]        상태 파일 직접 쓰기 (테스트)

            데이터: \(Paths.root.path)
            """)
        }
    }

    static func runApp() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            app.run()
        }
    }

    /// "4,5,hyper" → {"4차","5차","하이퍼"}
    static func parseTiers(_ text: String) -> Set<String> {
        Set(text.split(separator: ",").compactMap { raw -> String? in
            let t = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if t.hasPrefix("hyper") || t == "하이퍼" { return "하이퍼" }
            if let n = Int(t.replacingOccurrences(of: "차", with: "")), (1...6).contains(n) { return "\(n)차" }
            return t.isEmpty ? nil : String(raw)
        })
    }

    static func attempt(_ f: () throws -> Void) {
        do { try f() } catch { fail(error.localizedDescription) }
    }

    static func fail(_ msg: String) -> Never {
        FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
        exit(1)
    }
}
