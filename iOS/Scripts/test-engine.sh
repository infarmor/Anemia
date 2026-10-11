#!/usr/bin/env bash
#
# Тесты Go-движка на Mac (проверка серверов через прокси). Нужен macOS-бинарник
# Xray для локального тестового сервера и модуль с iOS-патчем, который готовит
# build-engine.sh.
#
#   ANEMIA_XRAY=Resources/xray bash iOS/Scripts/test-engine.sh
#
set -euo pipefail

IOS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$IOS_DIR/Scripts/go-env.sh"
WORK="$ANEMIA_CACHE/engine-build"
[[ -f "$WORK/go.mod" ]] || bash "$IOS_DIR/Scripts/build-engine.sh"

export ANEMIA_XRAY="$(cd "$(dirname "${ANEMIA_XRAY:?укажите ANEMIA_XRAY — путь к xray для macOS}")" && pwd)/$(basename "$ANEMIA_XRAY")"
cd "$IOS_DIR/Engine"
CGO_ENABLED=1 go test -modfile "$WORK/go.mod" -count=1 -run "${1:-Probe}" -v .
