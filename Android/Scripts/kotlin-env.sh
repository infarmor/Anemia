#!/usr/bin/env bash
#
# Sourced by the Android scripts: finds the JDK and the Kotlin compiler that
# Android Studio already ships, so the :core port can be compiled and its
# checks run without installing anything.
#
# Nothing is downloaded and nothing is written outside the build cache — the
# toolchain is the one the IDE itself uses.
#
#   ANEMIA_CACHE — build cache root (default ~/Library/Caches/Anemia)
#
ANEMIA_CACHE="${ANEMIA_CACHE:-$HOME/Library/Caches/Anemia}"
KOTLIN_CACHE="$ANEMIA_CACHE/android-core"

STUDIO="/Applications/Android Studio.app/Contents"

if [[ -z "${JAVA_HOME:-}" ]]; then
    for candidate in "$STUDIO/jbr/Contents/Home" \
                     "$(/usr/libexec/java_home 2>/dev/null || true)"; do
        [[ -x "$candidate/bin/javac" ]] && { JAVA_HOME="$candidate"; break; }
    done
fi
if [[ -z "${JAVA_HOME:-}" || ! -x "$JAVA_HOME/bin/javac" ]]; then
    echo "✗ JDK не найден: поставьте Android Studio или экспортируйте JAVA_HOME" >&2
    return 1 2>/dev/null || exit 1
fi

if [[ -z "${KOTLINC:-}" ]]; then
    for candidate in "$STUDIO/plugins/Kotlin/kotlinc/bin/kotlinc" "$(command -v kotlinc || true)"; do
        [[ -x "$candidate" ]] && { KOTLINC="$candidate"; break; }
    done
fi
if [[ -z "${KOTLINC:-}" ]]; then
    echo "✗ kotlinc не найден (ни в Android Studio, ни в PATH)" >&2
    return 1 2>/dev/null || exit 1
fi

export JAVA_HOME
export PATH="$JAVA_HOME/bin:$PATH"
export KOTLINC
# The compiler jar the generated classes run against.
KOTLIN_STDLIB="$(dirname "$(dirname "$KOTLINC")")/lib/kotlin-stdlib.jar"
export KOTLIN_STDLIB
