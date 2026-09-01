#!/bin/sh
# GitHub Release 만들기: ./scripts/release.sh 0.1.0
#   태그 생성·푸시 → 빌드 → 에셋 미포함 검사 → zip → gh release create
set -eu
cd "$(dirname "$0")/.."

VERSION="${1:?usage: ./scripts/release.sh <버전 (예: 0.1.0)>}"
TAG="v$VERSION"

if ! command -v gh >/dev/null; then echo "gh CLI가 필요합니다 (brew install gh)"; exit 1; fi
if [ -n "$(git status --porcelain)" ]; then echo "커밋 안 된 변경이 있습니다 — 먼저 커밋하세요"; exit 1; fi

echo "→ 태그 $TAG"
git tag "$TAG"
git push origin "$TAG"

echo "→ 빌드"
./scripts/build-app.sh

# 저장소 정책: 릴리즈에 게임 에셋(png 스프라이트 등)이 섞이면 안 된다.
# .app 은 실행 파일 + Info.plist 만 담는 구조 — 이미지 파일이 있으면 실패시킨다.
if find build/OverlayPet.app \( -name '*.png' -o -name '*.gif' -o -name '*.jpg' \) | grep -q .; then
    echo "중단: .app 안에 이미지 에셋이 들어 있습니다"; exit 1
fi

ZIP="OverlayPet-$TAG.zip"
echo "→ $ZIP"
rm -f "$ZIP"
ditto -c -k --keepParent build/OverlayPet.app "$ZIP"

echo "→ GitHub Release"
gh release create "$TAG" "$ZIP" --title "$TAG" --generate-notes
rm -f "$ZIP"
echo "완료: $(gh release view "$TAG" --json url -q .url)"
