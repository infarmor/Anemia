#!/usr/bin/env bash
#
# Два дешёвых шлюза для всего, что в этом репозитории пишется на shell и
# с русскими комментариями:
#
#  1. `bash -n` каждого скрипта. Правки в Scripts/, Server/ и Android/Scripts/
#     не компилируются: сломанная кавычка или незакрытый here-doc становятся
#     видны только в момент, когда скрипт что-то делает на сервере.
#  2. Иероглифы в кириллических комментариях. За один день это вылезло трижды
#     (латинская 'd' и 'б' оказывались японскими знаками, русское слово —
#     склеенным с иероглифом): компилятор о комментариях молчит, а рука печатает,
#     потому что CJK в раскладке рядом. Данные не трогаем (в фикстурах
#     иероглиф — это проверка, а не опечатка), смотрим только строки,
#     начинающиеся с комментария. Настоящие японские строки в тестах живут в
#     строковых литералах и под этот скан не попадают.
#
#   bash Scripts/verify-shell-hygiene.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Каталог, где скриптов нет намеренно: чужие сборки и фикстуры.
PRUNE=( -path ./.git -prune -o -path '*/build/*' -prune -o -path '*/.gradle/*' -prune -o \
        -path "$ROOT/Android/core/src/test/resources/*" -prune -o )

MIN_SCRIPTS=${MIN_SCRIPTS:-50}
scripts=()
while IFS= read -r file; do scripts+=("$file"); done < <(
    find "$ROOT" \( -path ./.git -o -path '*/build/*' -o -path '*/.gradle/*' \
        -o -path './Android/core/src/test/resources/*' \) -prune -o -name '*.sh' -print
)

syntax_bad=0
for file in "${scripts[@]}"; do
    if ! err="$(bash -n "$file" 2>&1)"; then
        syntax_bad=$((syntax_bad + 1))
        printf '✘ синтаксис: %s\n  %s\n' "${file#"$ROOT"/}" "$(head -1 <<<"$err")"
    fi
done

# 2) CJK в комментариях shell/Swift/Kotlin.
cjk_bad=0
while IFS= read -r -d '' file; do
    case "$file" in
        *.sh)  pattern='^[[:space:]]*#' ;;
        *.swift|*.kt) pattern='^[[:space:]]*//' ;;
        *) continue ;;
    esac
    hits="$(grep -n -E "$pattern" "$file" 2>/dev/null \
            | perl -CSD -ne 'print if /[\x{4E00}-\x{9FFF}\x{3040}-\x{30FF}]/' || true)"
    if [[ -n "$hits" ]]; then
        cjk_bad=$((cjk_bad + 1))
        printf '✘ иероглифы в комментариях: %s\n%s\n' "${file#"$ROOT"/}" "$(sed 's/^/    /' <<<"$hits")"
    fi
done < <(find "$ROOT" \( -path ./.git -o -path '*/build/*' -o -path '*/.gradle/*' \
             -o -path './Android/core/src/test/resources/*' \) -prune -o \
             \( -name '*.sh' -o -name '*.swift' -o -name '*.kt' \) -print0)

printf '— скриптов проверено: %d (минимум %d), с битым синтаксисом: %d; файлов с иероглифами в комментариях: %d\n' \
       "${#scripts[@]}" "$MIN_SCRIPTS" "$syntax_bad" "$cjk_bad"

# «Проверено 0 файлов» — не зелёный прогон: find мог не найти каталог.
fail=0
[[ ${#scripts[@]} -ge "$MIN_SCRIPTS" ]] || { echo "✘ скриптов найдено ${#scripts[@]}, ожидалось не меньше $MIN_SCRIPTS" >&2; fail=1; }
[[ $syntax_bad -eq 0 && $cjk_bad -eq 0 ]] || fail=1
exit $fail
