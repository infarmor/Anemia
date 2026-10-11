#!/usr/bin/env bash
#
# Компилирует :core (чистый Kotlin, без Android-зависимостей) и его проверки,
# затем запускает их. Это тот же слой, что на iOS живёт в Sources/LoaderCore,
# — разбор конфигов, список адресов, UAPI-скрипт, форматирование чисел.
#
#   bash Android/Scripts/test-core.sh
#   bash Android/Scripts/test-core.sh -k            # оставить классы
#
# Компилятор и JDK берутся из Android Studio (Scripts/kotlin-env.sh), ничего не
# скачивается.
set -euo pipefail

ANDROID_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ANDROID_DIR/Scripts/kotlin-env.sh"

SRC="$ANDROID_DIR/core/src/main/kotlin"
TEST_SRC="$ANDROID_DIR/core/src/test/kotlin"
OUT="$KOTLIN_CACHE/classes"

keep=0
[[ "${1:-}" == "-k" ]] && keep=1

[[ -d "$SRC" ]] || { echo "✗ нет $SRC" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT"

# bash 3.2 (the one macOS ships) has no mapfile.
sources=()
while IFS= read -r file; do sources+=("$file"); done < <(find "$SRC" "$TEST_SRC" -name "*.kt" | sort)
echo "→ kotlinc: ${#sources[@]} файлов"
"$KOTLINC" -nowarn -jvm-target 17 -d "$OUT" "${sources[@]}"

echo "→ проверки"
if [[ $keep -eq 0 ]]; then
    trap 'rm -rf "$OUT"' EXIT
fi

# bash 3.2 has no mapfile here either.
dirs=()
while IFS= read -r d; do dirs+=("$d"); done < <(
    for name in awg country links base64 xray bypass sub state sync score leak probe hysteria stats mask switch health engine; do
        echo "$ANDROID_DIR/core/src/test/resources/$name"
    done
)

run_checks() { java "$@" -cp "$OUT:$KOTLIN_STDLIB" app.anemia.core.ChecksKt "${dirs[@]}"; }

# Число проверок закреплено: иначе «проверки зелёные» могло значить, что
# половину `check(...)` из main() просто вычеркнули (проверено — без этой
# строки удаление проверки прогон не краснит).
EXPECTED_CHECKS=43

main_out="$(run_checks 2>&1)" || { echo "$main_out"; echo "✘ проверки" >&2; exit 1; }
echo "$main_out"
passed="$(grep -oE 'пройдено проверок: [0-9]+' <<<"$main_out" | grep -oE '[0-9]+$' || true)"
if [[ "$passed" != "$EXPECTED_CHECKS" ]]; then
    echo "✘ пройдено проверок: ${passed:-0}, ожидалось $EXPECTED_CHECKS" >&2
    exit 1
fi

# Второй прогон — та же JVM, но под локалью, где десятичные цифры печатаются
# не ASCII: `"%02d".format(9)` даёт «٠٩». Эталон-то из Swift, а Foundation
# `String(format:)` и `\(int)` цифровую систему локали не трогают — то есть
# любой формат без Locale.ROOT расходится с эталоном только на Android'е и
# только у пользователя с арабской/персидской/бенгальской локалью. Без этого
# прогона ключи дней трафика (`2026-09-24`) могли бы стать «٢٠٢٦-٠٩-٢٤» и
# рассыпаться при синхронизации.
locale_out="$(run_checks -Duser.language=ar -Duser.country=EG 2>&1)" || {
    echo "$locale_out"
    echo "✘ проверки под локалью ar-EG" >&2
    exit 1
}
# «^✔» считается побайтово (LC_ALL по умолчанию), поэтому только строки
# результатов, а не итоговое «✓ пройдено».
locale_passed=$(grep -c '^✔' <<<"$locale_out")
if [[ "$locale_passed" != "$EXPECTED_CHECKS" ]]; then
    echo "$locale_out"
    echo "✘ под ar-EG пройдено проверок: $locale_passed, ожидалось $EXPECTED_CHECKS" >&2
    exit 1
fi
# «^✔» считается побайтово (LC_ALL по умолчанию), поэтому только строки
# результатов, а не итоговое «✓ пройдено».
echo "→ тот же прогон под ar-EG: ✔ $locale_passed"

# Третий прогон — tr-TR: единственная массовая локаль, где строчная форма
# ASCII-буквы перестаёт быть ASCII («I».lowercase() = «ı», без точки). Именно
# на ней видно, что сравнение «похожа ли строка на отказ» складывает регистр
# по-соседски, а не по-турецки: Foundation-овский localizedCaseInsensitiveContains
# на устройстве с tr-локалью переставал видеть «failed» в «FAILED», и выбор
# строки для пользователя менялся бы от языка интерфейса. Цифры при этом
# остаются ASCII-ными, так что ar-EG этого не проверяет.
turkish_out="$(run_checks -Duser.language=tr -Duser.country=TR 2>&1)" || {
    echo "$turkish_out"
    echo "✘ проверки под локалью tr-TR" >&2
    exit 1
}
turkish_passed=$(grep -c '^✔' <<<"$turkish_out")
if [[ "$turkish_passed" != "$EXPECTED_CHECKS" ]]; then
    echo "$turkish_out"
    echo "✘ под tr-TR пройдено проверок: $turkish_passed, ожидалось $EXPECTED_CHECKS" >&2
    exit 1
fi
echo "→ тот же прогон под tr-TR: ✔ $turkish_passed"
