#!/usr/bin/env bash
#
# Собирает iOS/build/Anemia.ipa. Подпись Apple ставит GBox на телефоне, поэтому
# Xcode собирает без подписи, а скрипт добавляет только ad hoc подпись с
# entitlements — для подписчиков, которые берут права из бинарника.
#
#   bash iOS/Scripts/build-ipa.sh
#   CONFIGURATION=Debug bash iOS/Scripts/build-ipa.sh
#
set -euo pipefail

IOS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-Release}"
# Вне iCloud-папки Documents, как и сборка macOS.
SCRATCH="${SCRATCH:-/tmp/loader-build/ios}"
DERIVED="$SCRATCH/DerivedData"
STAGE="$SCRATCH/ipa"
IPA="$IOS_DIR/build/Anemia.ipa"

ARCHIVE="$IOS_DIR/Engine/build/AnemiaEngine.xcframework/ios-arm64/libanemia.a"
# Existence is not freshness. This script used to link whatever archive was
# lying around, and an `.ipa` built after an `engine.go` edit silently shipped
# the PREVIOUS engine — the `.ipa` looks brand new (it re-signs and repackages
# at 15:33) while the Go half of the tunnel is days old. Rebuild whenever any
# Go source or the xray patch is newer than the archive.
# Go source or the xray patch newer than the archive means the engine inside
# the `.ipa` is not the engine that was written. Each test is its own `if`:
# bash has no `or` between `[[ ]]` commands, and a `… ]]` / `or … ]]` chain
# silently ran `or` as a command, printed "command not found" and rebuilt
# nothing — the guard believed it had checked.
stale_engine=0
if [[ ! -f "$ARCHIVE" ]]; then
    stale_engine=1
elif [[ -n "$(find "$IOS_DIR/Engine" -name '*.go' -newer "$ARCHIVE" -print -quit)" ]]; then
    stale_engine=1
elif [[ -n "$(find "$IOS_DIR/Engine/patches" -name '*.patch' -newer "$ARCHIVE" -print -quit)" ]]; then
    stale_engine=1
fi
if [[ "$stale_engine" == 1 ]]; then
    echo "→ Go-исходники свежее архива движка — пересобираю"
    bash "$IOS_DIR/Scripts/build-engine.sh"
fi

echo "→ xcodebuild ($CONFIGURATION)"
xcodebuild \
    -project "$IOS_DIR/Anemia.xcodeproj" \
    -scheme Anemia \
    -configuration "$CONFIGURATION" \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$DERIVED" \
    -quiet \
    build

APP="$DERIVED/Build/Products/$CONFIGURATION-iphoneos/Anemia.app"
if [[ ! -d "$APP/PlugIns/AnemiaTunnel.appex" ]]; then
    echo "✗ в $APP нет PlugIns/AnemiaTunnel.appex" >&2
    exit 1
fi

rm -rf "$STAGE"
mkdir -p "$STAGE/Payload" "$(dirname "$IPA")"
ditto "$APP" "$STAGE/Payload/Anemia.app"
xattr -cr "$STAGE/Payload"

echo "→ ad hoc подпись с entitlements"
# Изнутри наружу: сначала расширения, потом приложение, которое их запечатывает.
codesign --force --sign - --generate-entitlement-der \
    --entitlements "$IOS_DIR/Config/AnemiaTunnel.entitlements" \
    "$STAGE/Payload/Anemia.app/PlugIns/AnemiaTunnel.appex"
# Виджетам права VPN нужны, чтобы видеть состояние туннеля.
codesign --force --sign - --generate-entitlement-der \
    --entitlements "$IOS_DIR/Config/AnemiaWidgets.entitlements" \
    "$STAGE/Payload/Anemia.app/PlugIns/AnemiaWidgets.appex"
codesign --force --sign - --generate-entitlement-der \
    --entitlements "$IOS_DIR/Config/Anemia.entitlements" \
    "$STAGE/Payload/Anemia.app"

rm -f "$IPA"
(cd "$STAGE" && zip -qr -X "$IPA" Payload)
echo "✓ $IPA ($(du -h "$IPA" | cut -f1 | tr -d ' '))"
