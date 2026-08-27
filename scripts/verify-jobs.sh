#!/usr/bin/env bash
# 전체 직업을 실제로 한 바퀴 돌려 스킬 이펙트 파이프라인을 검증한다.
#   직업당: 랭킹 API 로 표본 캐릭터 1명 → fetch → effect fetch(목록) → effect fetch --tiers N --all
#
# 결과 TSV 는 직업 하나가 끝날 때마다 바로 append 하므로 중간에 죽어도 부분 결과가 남는다.
# 상세 로그는 전부 파일로 뺀다 — `--all` 은 프레임마다 진행 상황을 찍어서 stdout 으로 받으면 감당이 안 된다.
#
#   ./scripts/verify-jobs.sh                 # 전체 (이미 끝난 직업은 건너뜀)
#   ./scripts/verify-jobs.sh 히어로 비숍       # 일부만
#   ./scripts/verify-jobs.sh --force 히어로    # 이미 있는 결과도 다시
set -euo pipefail
cd "$(dirname "$0")/.."

VERIFY_DIR="${VERIFY_DIR:-build/verify}"   # build/ 는 .gitignore 대상
LOG_DIR="$VERIFY_DIR/logs"
TSV="$VERIFY_DIR/result.tsv"
CATALOG="$VERIFY_DIR/catalog.tsv"          # 직업<TAB>캐릭터<TAB>랭킹class — 한 번 찾으면 재사용
PETS="$HOME/.claude/pet/pets"
SLEEP="${SLEEP:-3}"                        # 넥슨 초당 호출 제한 회피용 대기 (초)
TIERS="${TIERS:-4}"
RANK_DATE="${RANK_DATE:-$(date -v-1d +%Y-%m-%d)}"   # 랭킹은 어제 자가 안전하다
FORCE=0
KEEP=0                                     # 기본은 직업이 끝나면 이 스크립트가 만든 펫을 지운다

usage() {
    cat <<'USAGE'
usage: scripts/verify-jobs.sh [옵션] [직업…]

  --force        이미 result.tsv 에 있는 직업도 다시 돌린다
  --keep         검증용 펫·이펙트를 지우지 않는다 (기본은 직업이 끝나면 삭제)
  --sleep N      API 호출 사이 대기 (초, 정수, 기본 3)
  --tiers T      설치해 볼 차수 (기본 4)
  --date D       랭킹 기준일 YYYY-MM-DD (기본 어제)

  결과: build/verify/result.tsv,  직업별 상세 로그: build/verify/logs/<직업>.log
USAGE
}

JOBS=""
while [ $# -gt 0 ]; do
    case "$1" in
        --force) FORCE=1 ;;
        --keep) KEEP=1 ;;
        --sleep) SLEEP="$2"; shift ;;
        --tiers) TIERS="$2"; shift ;;
        --date) RANK_DATE="$2"; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "모르는 옵션: $1" >&2; usage >&2; exit 2 ;;
        *) JOBS="$JOBS$1"$'\n' ;;
    esac
    shift
done

# ── 직업표 ──────────────────────────────────────────────────────────────────
# 직업<TAB>랭킹 class 파라미터.
# ⚠ 랭킹 API 는 틀린 class 값에 400 을 주지 않고 "그 직업군의 첫 전직" 을 조용히 돌려준다.
#   (예: `전사-아크메이지(불,독)` → 200건이 전부 전사-히어로)
#   그래서 응답의 sub_class_name 이 기대값과 정확히 같은지 반드시 확인한다.
# 하위 전직이 없는 직업은 `<이름>-` 처럼 뒤를 비운다. `프렌즈 월드` 는 공백 포함.
JOB_TABLE=$(cat <<'TSV'
히어로	전사-히어로
팔라딘	전사-팔라딘
다크나이트	전사-다크나이트
아크메이지(불,독)	마법사-아크메이지(불,독)
아크메이지(썬,콜)	마법사-아크메이지(썬,콜)
비숍	마법사-비숍
매지션	마법사-매지션
보우마스터	궁수-보우마스터
신궁	궁수-신궁
패스파인더	궁수-패스파인더
나이트로드	도적-나이트로드
섀도어	도적-섀도어
듀얼블레이더	도적-듀얼블레이더
바이퍼	해적-바이퍼
캡틴	해적-캡틴
캐논마스터	해적-캐논마스터
초보자	초보자-
소울마스터	기사단-소울마스터
플레임위자드	기사단-플레임위자드
윈드브레이커	기사단-윈드브레이커
나이트워커	기사단-나이트워커
스트라이커	기사단-스트라이커
미하일	기사단-미하일
노블레스	기사단-노블레스
아란	아란-
에반	에반-
메르세데스	메르세데스-
팬텀	팬텀-
루미너스	루미너스-
은월	은월-
배틀메이지	레지스탕스-배틀메이지
와일드헌터	레지스탕스-와일드헌터
메카닉	레지스탕스-메카닉
데몬슬레이어	레지스탕스-데몬슬레이어
데몬어벤져	레지스탕스-데몬어벤져
제논	레지스탕스-제논
블래스터	레지스탕스-블래스터
시티즌	레지스탕스-시티즌
데몬	레지스탕스-데몬
카이저	카이저-
카인	카인-
카데나	카데나-
엔젤릭버스터	엔젤릭버스터-
일리움	일리움-
아크	아크-
아델	아델-
칼리	칼리-
호영	호영-
라라	라라-
제로	초월자-제로
키네시스	프렌즈 월드-키네시스
렌	렌-
하야토	하야토-
칸나	칸나-
젯트	젯트-
비스트테이머	비스트테이머-
모쿠아	모쿠아-
젠	젠-
TSV
)

# ── 차수 기대치 예외 ────────────────────────────────────────────────────────
# mapleeditors 에 6차가 아직 안 올라온 직업. 코드 버그가 아니라 사이트 미등재라 "누락" 으로 세지 않는다.
NO_SIXTH=" 바이퍼 캡틴 캐논마스터 미하일 아란 에반 메르세데스 루미너스 은월 카이저 카인 카데나 엔젤릭버스터 젯트 모쿠아 젠 "
# 하이퍼가 없는 직업. 제로는 실제 게임에도 하이퍼가 없고, 모쿠아는 사이트 미등재.
NO_HYPER=" 제로 모쿠아 "
# 전직 전 페이지 — 기본(0차) 스킬만 있다
BEGINNER_ONLY=" 초보자 노블레스 시티즌 데몬 "
# mapleeditors 에 전용 페이지가 없어 계열 공용 5차만 쓰는 직업
FIFTH_ONLY=" 렌 "
# 페이지가 차수가 아니라 동물별로 나뉘어 전부 4차로 묶이는 직업
FOURTH_ONLY=" 비스트테이머 "

BIN="$(swift build -c release --show-bin-path)/OverlayPet"
[ -x "$BIN" ] || { echo "빌드 먼저: swift build -c release" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 가 필요합니다" >&2; exit 1; }

# API 키. 절대 화면·로그에 찍지 않는다.
API_KEY="${NEXON_API_KEY:-}"
if [ -z "$API_KEY" ] && [ -f .env ]; then
    API_KEY=$(sed -n 's/^[[:space:]]*NEXON_API_KEY[[:space:]]*=[[:space:]]*//p' .env | head -1 | tr -d "\"'" | tr -d '\r')
fi
[ -n "$API_KEY" ] || { echo "NEXON_API_KEY 가 없습니다 (.env 또는 환경변수)" >&2; exit 1; }

# 사용자가 쓰고 있는 펫은 검증이 끝나도 지우지 않는다.
ACTIVE_PET=$(python3 -c 'import json,os,sys
try: print(json.load(open(os.path.expanduser("~/.claude/pet/config.json"))).get("activePet") or "")
except Exception: print("")')

mkdir -p "$LOG_DIR"
[ -f "$TSV" ] || printf '%s\n' $'직업\t캐릭터\t차수목록\t차수누락\t설치개수\t비고' > "$TSV"
touch "$CATALOG"

class_for() { printf '%s\n' "$JOB_TABLE" | awk -F'\t' -v j="$1" '$1==j{print $2; exit}'; }
cached_char() { awk -F'\t' -v j="$1" '$1==j{print $2; exit}' "$CATALOG"; }
already_done() { awk -F'\t' -v j="$1" 'NR>1 && $1==j{f=1} END{exit !f}' "$TSV"; }
# 공백으로 감싼 목록에 들어 있나
contains() { case "$1" in *" $2 "*) return 0 ;; *) return 1 ;; esac; }

# 이 직업에 있어야 할 차수 (공백 구분)
expected_tiers() {
    if contains "$BEGINNER_ONLY" "$1"; then echo "기본"; return; fi
    if contains "$FIFTH_ONLY" "$1"; then echo "5차"; return; fi
    if contains "$FOURTH_ONLY" "$1"; then echo "4차"; return; fi
    t="1차 2차 3차 4차 5차"
    contains "$NO_HYPER" "$1" || t="$t 하이퍼"
    contains "$NO_SIXTH" "$1" || t="$t 6차"
    echo "$t"
}

# 랭킹 API 로 표본 캐릭터 1명. 성공하면 캐릭터명을, 실패하면 사유를 찍고 1 을 반환.
pick_character() {
    python3 - "$1" "$RANK_DATE" "$API_KEY" <<'PY'
import json, sys, urllib.parse, urllib.request
cls, date, key = sys.argv[1:4]
want = cls.split("-", 1)[1] if "-" in cls else ""   # 기대하는 sub_class_name
url = "https://open.api.nexon.com/maplestory/v1/ranking/overall?" + urllib.parse.urlencode(
    {"date": date, "class": cls, "page": 1})
try:
    rows = json.load(urllib.request.urlopen(
        urllib.request.Request(url, headers={"x-nxopen-api-key": key}), timeout=30)).get("ranking") or []
except Exception as e:
    print("ERR %s" % e); sys.exit(1)
if not rows:
    print("EMPTY"); sys.exit(1)
for r in rows:
    if (r.get("sub_class_name") or "") == want:
        print(r["character_name"]); sys.exit(0)
# sub_class_name 이 다르면 넥슨이 엉뚱한 직업군으로 조용히 폴백한 것이다.
got = sorted({"%s|%s" % (r.get("class_name") or "", r.get("sub_class_name") or "") for r in rows})
print("MISMATCH %s" % ",".join(got[:3])); sys.exit(1)
PY
}

# 로그에서 지표를 뽑아 TSV 가운데 3칸(차수목록·차수누락·설치개수)을 찍는다.
metrics() {
    python3 - "$1" "$2" "$3" <<'PYEOF'
import re, sys
list_log, install_log, expected = sys.argv[1:4]

def read(p):
    try:
        return open(p, encoding="utf-8", errors="replace").read()
    except OSError:
        return ""

listing, install = read(list_log), read(install_log)

# 차수: 목록 출력의 "[4차]" 머리글 (문서 순서 유지)
seen, order = set(), []
for t in re.findall(r"^\[(.+)\]$", listing, re.M):
    if t not in seen:
        seen.add(t); order.append(t)
missing = [t for t in expected.split() if t not in seen]

m = re.search(r"(\d+)개 설치", install)                    # "37개 설치"
installed = m.group(1) if m else "실패"

print("\t".join(["+".join(order) or "-", "+".join(missing) or "-", installed]))
PYEOF
}

# 이 스크립트가 새로 만든 펫만 지운다. 기본 펫·활성 펫·원래 있던 펫은 절대 건드리지 않는다.
drop_pet() {
    case "$1" in
        ""|.|..|default) return 0 ;;
    esac
    if [ "$1" = "$ACTIVE_PET" ]; then return 0; fi
    if [ "$2" != "new" ]; then return 0; fi
    rm -rf "$PETS/$1"
}

run_job() {
    local job="$1" log list_log note cls char pet before fresh row
    log="$LOG_DIR/$job.log"
    list_log="$LOG_DIR/$job.list.log"
    note=""

    cls=$(class_for "$job")
    if [ -z "$cls" ]; then
        printf '%s\t-\t-\t-\t-\t-\t-\t%s\n' "$job" "직업표에없음" >> "$TSV"
        return 1
    fi

    char=$(cached_char "$job")
    if [ -z "$char" ]; then
        if char=$(pick_character "$cls"); then
            printf '%s\t%s\t%s\n' "$job" "$char" "$cls" >> "$CATALOG"
        else
            printf '%s\t-\t-\t-\t-\t-\t-\t%s\n' "$job" "랭킹실패($char)" >> "$TSV"
            return 1
        fi
        sleep "$SLEEP"
    fi

    before=$(ls "$PETS" 2>/dev/null || true)
    { echo "=== $job / $char / $cls"; echo "### fetch"; } > "$log"
    if ! "$BIN" fetch "$char" --no-use >> "$log" 2>&1; then
        printf '%s\t%s\t-\t-\t-\t%s\n' "$job" "$char" "fetch실패" >> "$TSV"
        return 1
    fi
    pet=$(awk -F': ' '/^설치 완료: /{print $2}' "$log" | tail -1)
    if [ -z "$pet" ]; then
        printf '%s\t%s\t-\t-\t-\t%s\n' "$job" "$char" "펫ID를못읽음" >> "$TSV"
        return 1
    fi
    fresh=old
    printf '%s\n' "$before" | grep -Fxq "$pet" || fresh=new
    sleep "$SLEEP"

    echo "### effect fetch (목록)" >> "$log"
    "$BIN" effect fetch --pet "$pet" > "$list_log" 2>&1 || note="${note}목록실패;"

    echo "### effect fetch --tiers $TIERS --all" >> "$log"
    "$BIN" effect fetch --pet "$pet" --tiers "$TIERS" --all >> "$log" 2>&1 || note="${note}설치실패;"

    row=$(metrics "$list_log" "$log" "$(expected_tiers "$job")")
    if contains "$NO_SIXTH" "$job"; then note="${note}6차사이트미등재;"; fi
    if contains "$NO_HYPER" "$job"; then note="${note}하이퍼없음;"; fi
    printf '%s\t%s\t%s\t%s\n' "$job" "$char" "$row" "${note:--}" >> "$TSV"

    if [ "$KEEP" = 0 ]; then drop_pet "$pet" "$fresh"; fi
    return 0
}

if [ -n "$JOBS" ]; then
    LIST="$JOBS"
else
    LIST=$(printf '%s\n' "$JOB_TABLE" | cut -f1)
fi

echo "결과: $TSV   로그: $LOG_DIR/   기준일: $RANK_DATE"
printf '%s\n' "$LIST" | while IFS= read -r job; do
    [ -n "$job" ] || continue
    if already_done "$job"; then
        if [ "$FORCE" = 0 ]; then
            echo "· $job (건너뜀)"
            continue
        fi
        awk -F'\t' -v j="$job" 'NR==1 || $1!=j' "$TSV" > "$TSV.tmp" && mv "$TSV.tmp" "$TSV"
    fi
    printf '· %s … ' "$job"
    if run_job "$job"; then
        echo "ok"
    else
        echo "실패 (로그: $LOG_DIR/$job.log)"
        sleep 15   # 연달아 실패하면 넥슨 호출 제한일 가능성이 크다. 조금 더 쉰다.
    fi
    sleep "$SLEEP"
done

echo
column -t -s $'\t' "$TSV" 2>/dev/null || cat "$TSV"
