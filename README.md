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

## 스킬 이펙트

캐릭터를 가져오면 그 직업(전직 경로)의 스킬 목록을 [mapleeditors.com](https://mapleeditors.com/skills/)에서 읽어 와 **받을 스킬을 체크**합니다 — 검색 가능, 차수 줄을 누르면 그 차수 전체 토글. 스킬을 고르면 그 스킬의 변형(Effect·Hit·Ball…)을 전부 받고, 상태에 붙이면 조각이 게임 순서대로 재생됩니다 — `Prepare/Charge → Keydown/Loop → End`는 차례로, `Effect`는 본 동작과 동시에, `Tile`은 앞으로 퍼지며, `Hit/Mob`은 살짝 늦게 앞쪽에. 소환수 조각은 제외. 따로 고를 건 없고, 조각 하나만 쓰고 싶을 때만 CLI `effect set`으로 지정합니다. 큰 이펙트는 512px로 줄여 저장하고 화면에서는 창 크기에 맞춰 축소됩니다. 나중에 우클릭 → **직업 스킬 이펙트 받기…** 로 더 받을 수 있습니다.

받은 스킬은 **상태별 이펙트** 메뉴에서 `상태 → 차수 → 스킬`로 고르고, **이펙트 재생**으로 바로 확인합니다.

스킬 이름은 한글로 표시됩니다. 캐릭터를 가져올 때 넥슨 API로 **본인 캐릭터의 스킬(한글 이름·아이콘)** 을 읽고, [maplestorywiki.net](https://maplestorywiki.net) 직업 페이지의 스킬 아이콘(영문 이름)과 픽셀 단위로 같은 것끼리 짝지어 `pets/<id>/skill-names.json`에 둡니다. 아이콘이 거의 같고 다른 후보와 확실히 구분될 때만 매칭하므로 틀린 이름은 붙지 않고, 못 맞춘 스킬(KMS/GMS 아이콘이 다른 것, 아직 안 배운 스킬)은 영문으로 남습니다. `OverlayPet effect names`로 다시 만들 수 있습니다.

```sh
OverlayPet effect fetch                         # 활성 펫 직업 스킬 목록 (차수별)
OverlayPet effect fetch --tiers 4,hyper,5       # 그 차수만 받기
OverlayPet effect fetch https://mapleeditors.com/warrior/ --skill Raging-Blow-Effect-1 --state done
OverlayPet effect set bash boomerang-stab-effect
OverlayPet effect set done none
```

직접 넣을 수도 있습니다: `~/.claude/pet/effects/<name>/effect.json` + `sheet.png`

```json
{"frameWidth":57,"frameHeight":118,"frames":13,"columns":4,"fps":12,"loop":false,"anchor":"bottom","scale":1.5}
```

이펙트 이미지 역시 사용자가 런타임에 받아오며 저장소에는 포함되지 않습니다.

## 라이선스

MIT (코드만). 내려받은 캐릭터 이미지는 포함되지 않습니다.
