#!/usr/bin/env bash
#
# Ставит то, чего на этой машине нет для сборки Android-порта, и проверяет
# окружение. Ничего не собирает — только готовит.
#
#   bash Android/Scripts/bootstrap.sh
#
# Требуется: macOS с Homebrew. SDK уже лежит в ~/Library/Android/sdk, но без
# JDK, NDK и CMake там делать нечего.
set -euo pipefail

fail=0

need_brew() {
    command -v brew >/dev/null || { echo "✗ Homebrew не найден — поставьте с brew.sh" >&2; exit 1; }
}

echo "→ проверки"

if java -version >/dev/null 2>&1; then
    java -version 2>&1 | head -1
else
    need_brew
    # `command -v java` не годится: в macOS всегда есть заглушка, которая
    # умеет только сказать «не найден рантайм».
    echo "  нет JDK (или не экспортирован JAVA_HOME):"
    echo "    export JAVA_HOME=\$(brew --prefix openjdk@21)/libexec/openjdk.jdk/Contents/Home"
    fail=1
fi

SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
if [[ -d "$SDK" ]]; then
    echo "  SDK: $SDK"
    echo "  платформы: $(ls "$SDK/platforms" 2>/dev/null | tr '\n' ' ')"
    echo "  build-tools: $(ls "$SDK/build-tools" 2>/dev/null | tr '\n' ' ')"
else
    echo "  ✗ SDK не найден: скачайте command-line tools и выполните"
    echo "      sdkmanager \"platforms;android-36\" \"build-tools;36.0.0\" \"ndk;28.2.13676358\""
    fail=1
fi
# Для `adb install` и проверки туннеля нужен ещё и эмулятор либо устройство:
# `sdkmanager "platform-tools" "emulator"` плюс образ системы, либо своё
# устройство в режиме разработчика.

if [[ -d "$SDK/ndk" ]] && ls "$SDK/ndk"/*/ >/dev/null 2>&1; then
    echo "  NDK: $(ls "$SDK/ndk" | tail -1)"
else
    need_brew
    echo "  нет NDK — ставим (нужен для CGO-сборки движка):"
    echo "    brew install --cask android-ndk"
    echo "  или через sdkmanager: sdkmanager \"ndk;28.2.13676358\""
    fail=1
fi

# CMake не нужен: JNI-шим собирается прямым вызовом clang из NDK
# (`Scripts/build-engine.sh`), а Gradle-сборка сама тянет всё остальное.

# Go для сборки движка качается по тем же pinned-версиям, что и на iOS.
if [[ -x "$HOME/Library/Caches/Anemia/toolchains" ]] || \
   ls "$HOME/Library/Caches/Anemia/toolchains"/*/bin/go >/dev/null 2>&1; then
    echo "  Go: кэш инструментов на месте (iOS/Scripts/go-env.sh)"
else
    echo "  Go скачается сам при первой сборке движка"
fi

if [[ $fail -eq 0 ]]; then
    echo "✓ окружение готово"
else
    echo "✗ доустановите перечисленное и запустите скрипт снова" >&2
    exit 1
fi
