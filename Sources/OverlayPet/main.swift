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
            Task {
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
        case "effects":
            let list = Effect.installed()
            print(list.isEmpty ? "설치된 이펙트 없음. \(Paths.effects.path)/<name>/effect.json + sheet.png 를 넣으세요." : list.joined(separator: "\n"))
        case "state":
            // 디버그: state <name> [message]
            guard args.count >= 2 else { fail("usage: state <name> [message]") }
            attempt { try PetStateFile(state: args[1], tool: nil, message: args.count > 2 ? args[2...].joined(separator: " ") : nil,
                                       cwd: nil, sessionId: nil, ts: Date().timeIntervalSince1970).write() }
        default:
            print("""
            OverlayPet — Claude Code 상태를 보여주는 데스크톱 펫

              run                       오버레이 실행 (기본)
              fetch <캐릭터명> [--api-key K] [--weapon]   넥슨 API 로 스프라이트 시트 생성·설치
              pets | use <id>           설치된 펫 목록 / 선택
              hooks install|uninstall|status             Claude Code 훅 설정
              effects                   설치된 이펙트 목록
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
