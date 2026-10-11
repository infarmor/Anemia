#!/usr/bin/env bash
#
# Лестница восстановления — тесты без модуля.
#
#   bash Android/Scripts/test-recovery.sh
#
# `Recovery.kt` — чистая логика (ни сокета, ни Context, ни Compose), и проверять
# её хочется даже тогда, когда `:app` не собирается: экран, сервис и проводка
# меняются чаще, чем успевает доехать сборка. Здесь компилируются ровно два
# файла — сам алгоритм и его тесты — против классов `:core` и junit из кэша
# Gradle. Выход — 0, если прошли все случаи.
#
# Мутации проверяются так же локально: поправить Recovery.kt, запустить, до
# отката убедиться, что тесты покраснели.
set -uo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
src="$here/app/src/main/kotlin/app/anemia/data/Recovery.kt"
test="$here/app/src/test/kotlin/app/anemia/data/RecoveryTest.kt"
[[ -f "$src" && -f "$test" ]] || { echo "✗ нет $src или $test" >&2; exit 1; }

J="$HOME/.gradle/caches/modules-2/files-2.1"
JAVA="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home}/bin/java"
[[ -x "$JAVA" ]] || { echo "✗ нет $JAVA (нужен openjdk@21)" >&2; exit 1; }

pick() { find "$1" -name "$2" -print 2>/dev/null | sort | tail -1; }
KC=$(pick "$J/org.jetbrains.kotlin/kotlin-compiler-embeddable" "kotlin-compiler-embeddable-*.jar")
STDLIB=$(pick "$J/org.jetbrains.kotlin/kotlin-stdlib/2.0.21" "kotlin-stdlib-2.0.21.jar")
ANN=$(pick "$J/org.jetbrains/annotations" "annotations-13.0.jar")
SCRIPTS=$(pick "$J/org.jetbrains.kotlin/kotlin-script-runtime" "kotlin-script-runtime-*.jar")
TROVE=$(pick "$J/org.jetbrains.intellij.deps/trove4j" "trove4j-*.jar")
COR=$(pick "$J/org.jetbrains.kotlinx" "kotlinx-coroutines-core-jvm-*.jar")
REFLECT=$(pick "$J/org.jetbrains.kotlin/kotlin-reflect" "kotlin-reflect-*.jar")
JUNIT=$(pick "$J/junit/junit" "junit-4.13.2.jar")
HAM=$(pick "$J/org.hamcrest/hamcrest-core" "hamcrest-core-1.3.jar")
CORE="$here/core/build/classes/kotlin/main"

for v in KC STDLIB JUNIT HAM; do [[ -n "${!v:-}" ]] || { echo "✗ в кэше Gradle нет $v" >&2; exit 1; }; done
if [[ ! -d "$CORE" ]]; then
    echo "→ классов :core нет, собираю их"
    (cd "$here" && "./gradlew" :core:compileKotlin --offline >/dev/null) || { echo "✗ :core не собрался" >&2; exit 1; }
fi

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
"$JAVA" -cp "$KC:$STDLIB:$ANN:$SCRIPTS:$TROVE:$COR:$REFLECT" \
    org.jetbrains.kotlin.cli.jvm.K2JVMCompiler -nowarn -no-stdlib \
    -cp "$CORE:$JUNIT:$STDLIB" -d "$out" "$src" "$test" || { echo "✗ компиляция упала" >&2; exit 1; }
"$JAVA" -cp "$out:$CORE:$JUNIT:$HAM:$STDLIB:$ANN" org.junit.runner.JUnitCore app.anemia.data.RecoveryTest
