# OverlayPet

Claude Code 작업 상태를 보여주는 macOS 데스크톱 펫. 투명 오버레이에 스프라이트 애니메이션을 띄우고, Claude Code 훅이 남긴 상태에 따라 동작과 말풍선이 바뀝니다.

- 투명·항상 위·모든 스페이스, 독 아이콘 없음, 투명 영역은 클릭 통과
- 드래그로 이동, 위치 기억
- 상태별 애니메이션 + 말풍선, 오래 조용하면 잠듦
- 넥슨 Open API로 자기 캐릭터를 가져오는 fetcher 내장
- 이펙트 레이어(사용자 에셋), 훅 설치/제거, 로그인 시 실행

이 저장소에는 스프라이트 이미지가 없습니다. 캐릭터 이미지는 각자 넥슨 Open API로 받아오며 저작권은 NEXON에 있습니다. 이 프로젝트는 NEXON과 무관합니다.

## 설치

```sh
./scripts/build-app.sh                     # Xcode 없이 CLT만으로 빌드 (macOS 13+)
cp -R build/OverlayPet.app /Applications/
open /Applications/OverlayPet.app
```

## 사용

1. https://openapi.nexon.com 에서 API 키 발급
2. 펫 우클릭 → **캐릭터 가져오기…** → 키·캐릭터명 입력
3. 펫 우클릭 → **Claude Code 훅 설치** → Claude Code 재시작

터미널에서도 됩니다 (`.env`의 `NEXON_API_KEY`를 읽음):

```sh
OverlayPet fetch <캐릭터명> [--weapon]
OverlayPet hooks install|uninstall|status
OverlayPet state error "테스트"        # 말풍선/애니메이션 확인
```

## 상태 매핑

| 훅 | 상태 | 애니메이션 |
|---|---|---|
| SessionStart / Stop | start / done | 점프 (1회 후 idle) |
| UserPromptSubmit | prompt | 대기 |
| PreToolUse Bash | bash | 공격 |
| PreToolUse Edit·Write | edit | 걷기 |
| Notification | notify | 손 흔들기 |
| PostToolUseFailure | error | 유령 |
| SessionEnd | end | 엎드리기 |

세션이 여러 개면 마지막에 프롬프트를 친 세션을 따라가고, 다른 세션은 error·notify만 보여줍니다. 매핑·배율·fps 등은 `~/.claude/pet/config.json`에서 바꿉니다.

## 이펙트

`~/.claude/pet/effects/<name>/effect.json` + `sheet.png`를 넣고 `config.json`에 `"effects": {"done": "<name>"}`로 연결합니다.

```json
{"frameWidth":200,"frameHeight":200,"frames":12,"columns":6,"fps":12,"loop":false}
```

## 라이선스

MIT (코드만). 내려받은 캐릭터 이미지는 포함되지 않습니다.
