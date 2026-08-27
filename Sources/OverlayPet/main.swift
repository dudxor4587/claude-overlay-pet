import AppKit

@main
enum Main {
    static func main() {
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
            // effect list | effect fetch <페이지URL> [--skill NAME] [--state S] | effect set <state> <name|none>
            let sub = Array(args.dropFirst())
            switch sub.first {
            case nil, "list":
                let list = Effect.installed(), cfg = Config.load()
                if list.isEmpty { print("설치된 이펙트 없음. effect fetch <mapleeditors 페이지 URL> 로 가져오세요.") }
                for e in list {
                    let states = cfg.effects.filter { $0.value == e }.map(\.key).sorted().joined(separator: ",")
                    print(states.isEmpty ? "  \(e)" : "  \(e)  ← \(states)")
                }
            case "fetch":
                var url: URL?, skill: String?, state: String?, all = false, tiers: Set<String>?
                var it = sub.dropFirst().makeIterator()
                while let a = it.next() {
                    switch a {
                    case "--skill": skill = it.next()
                    case "--state": state = it.next()
                    case "--all": all = true
                    case "--tiers": tiers = it.next().map(EffectImporter.parseTiers)
                    default: url = URL(string: a)
                    }
                }
                // URL 이 없으면 활성 펫의 직업(경로) 스킬
                var jobName: String?
                SkillNames.load(petId: Config.load().activePet)
                if url == nil {
                    let cfg = Config.load()
                    guard let id = cfg.activePet, let m = try? PetManifest.load(petId: id), let job = m.jobName else {
                        fail("활성 펫에 직업 정보가 없습니다. effect fetch <페이지URL> 로 지정하세요.")
                    }
                    jobName = job
                }
                let sem = DispatchSemaphore(value: 0)
                var result: Result<String?, Error>!
                Task.detached {
                    do {
                        let skills: [EffectImporter.Skill]
                        if let url { skills = try await EffectImporter.listSkills(pages: [url]) }
                        else { skills = try await JobPages.skills(forJob: jobName!) }
                        if all || tiers != nil {
                            let picked = tiers.map { t in skills.filter { t.contains($0.tier) } } ?? skills
                            let names = await EffectImporter.installAll(picked) { print($0) }
                            print("\(names.count)개 설치 → \(Paths.effects.path)")
                            result = .success(nil); sem.signal(); return
                        }
                        guard let skill else {
                            var lastTier = ""
                            for s in skills.sorted(by: { ($0.tierOrder, $0.displayName) < ($1.tierOrder, $1.displayName) }) {
                                if s.tier != lastTier { lastTier = s.tier; print("[\(s.tier)]") }
                                print("  \(s.displayName)  (\(s.frames.count))")
                            }
                            result = .success(nil); sem.signal(); return
                        }
                        guard let pick = skills.first(where: { $0.name.lowercased() == skill.lowercased() }) else {
                            throw PetError("스킬을 찾을 수 없음: \(skill). effect fetch <URL> 로 목록 확인")
                        }
                        result = .success(try await EffectImporter.install(pick) { print($0) })
                    } catch { result = .failure(error) }
                    sem.signal()
                }
                sem.wait()
                switch result! {
                case .success(let name?):
                    print("→ \(Paths.effectDirectory(name).path)")
                    if let state {
                        var cfg = Config.load(); cfg.effects[state] = name
                        attempt { try cfg.save() }
                        print("\(state) → \(name)")
                    }
                case .success(nil): break
                case .failure(let e): fail(e.localizedDescription)
                }
            case "names":
                // 활성 펫의 한글 스킬명 표 (다시) 만들기
                guard let id = Config.load().activePet else { fail("활성 펫이 없습니다") }
                guard let key = APIKey.resolve() else { fail("NEXON_API_KEY 필요 (.env)") }
                let sem = DispatchSemaphore(value: 0)
                var result: Result<(matched: Int, total: Int), Error>!
                Task.detached {
                    do { result = .success(try await SkillNames.resolve(petId: id, apiKey: key) { print($0) }) } catch { result = .failure(error) }
                    sem.signal()
                }
                sem.wait()
                switch result! {
                case .success(let r): print("한글 스킬명 \(r.matched)/\(r.total) → \(SkillNames.fileURL(petId: id).path)")
                case .failure(let e): fail(e.localizedDescription)
                }
            case "set":
                guard sub.count >= 3 else { fail("usage: effect set <state> <name[,name…]|none>") }
                var cfg = Config.load()
                if sub[2] == "none" { cfg.effects[sub[1]] = nil }
                else {
                    // "a,b,c" 로 여러 변형을 겹쳐 재생
                    let names = sub[2].split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                    let installed = Effect.installed()
                    for n in names where !installed.contains(n) { fail("설치되지 않은 이펙트: \(n)") }
                    cfg.effects[sub[1]] = names.joined(separator: ",")
                }
                attempt { try cfg.save() }
                print("\(sub[1]) → \(sub[2])")
            default: fail("usage: effect list | fetch [URL] [--tiers 4,5,hyper | --skill NAME] [--state S] | names | set <state> <name|none>")
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
              effect fetch [페이지URL] [--tiers 4,5,hyper | --all | --skill NAME] [--state S]   스킬 이펙트 가져오기 (URL 없으면 활성 펫 직업)
              effect set <state> <name|none>              상태에 이펙트 연결
              effect names              활성 펫 스킬 한글 이름 표 만들기 (캐릭터 가져올 때 자동)
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

    static func attempt(_ f: () throws -> Void) {
        do { try f() } catch { fail(error.localizedDescription) }
    }

    static func fail(_ msg: String) -> Never {
        FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
        exit(1)
    }
}
