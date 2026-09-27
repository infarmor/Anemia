#!/usr/bin/env bash
#
# Наблюдатель за лестницей восстановления: рвёт туннель у системы под ногами и
# смотрит, поднимет ли его приложение само — по logcat и по интерфейсу, а не по
# тому, что о себе сообщает экран.
#
#   bash Android/Scripts/verify-ladder.sh            # обрыв живого туннеля
#   bash Android/Scripts/verify-ladder.sh hold       # обрыв без линка
#   bash Android/Scripts/verify-ladder.sh stop       # остановка плиткой посреди эпизода
#
# Режим `drop`: приложение должно заметить снятый интерфейс (два пропуска тика,
# ~6 с), сказать «восстановление» и поднять туннель заново. `ip link del tun0`
# требует root на устройстве (`adb root` на google_apis-образе), и это честная
# подделка: интерфейс исчезает, дескриптор остаётся — ровно то, что видит
# сервис, когда система забирает туннель у умершего транспорта.
#
# Режим `hold`: то же, но линк гасится целиком (wifi + data) на HOLD_OFF_SECONDS.
# Смысл замера — сколько ступенек ушло, пока сети не было: `establish()` поднимает
# туннель и без подложки, так что «пытайся сколько влезет» выглядело бы успехом.
# Сборка без ступеньки `Hold` здесь честно падает в ✗.
#
# Выход — 0, если туннель вернулся сам; 1 иначе. «Приложение открыто» и
# «уведомление на месте» ничего не доказывают: см. verify-tunnel.sh.
set -uo pipefail

SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ADB="$SDK/platform-tools/adb"
MODE="${1:-drop}"
# Обрыв замечается за два пропуска тика (2 × 3 с), плюс backoff первой
# ступеньки; запас — на медленный эмулятор.
DEADLINE="${DEADLINE:-40}"
# Сколько секунд в режиме `hold` сидеть без линка: должно хватить на два тика
# наблюдателя, иначе лестница успнет начаться до паузы.
HOLD_OFF_SECONDS="${HOLD_OFF_SECONDS:-10}"
fail=0

# Русское согласование с числом — как `Formatting.plural` в :core: «1 попытка»,
# «2 попытки», «5 попыток». Без этого отчёт читается как машинный перевод.
plural() {
    local n=$1 one=$2 few=$3 many=$4 form
    case $(( (n % 100 >= 11 && n % 100 <= 14) ? 2 : n % 10 )) in
        1) form=$one ;;
        2) form=$few ;;
        *) form=$many ;;
    esac
    echo "$n $form"
}

command -v "$ADB" >/dev/null || { echo "✗ нет $ADB" >&2; exit 1; }
"$ADB" get-state >/dev/null 2>&1 || { echo "✗ устройство не подключено" >&2; exit 1; }

if [[ -z "$("$ADB" shell ip -o link show tun0 2>/dev/null | tr -d '\r')" ]]; then
    echo "✗ туннеля нет: сначала «Подключить» в приложении (см. verify-tunnel.sh)" >&2
    exit 1
fi

"$ADB" root >/dev/null 2>&1
sleep 1
if [[ "$("$ADB" shell id -u 2>/dev/null | tr -d '\r')" != "0" ]]; then
    echo "✗ нужен root в adb shell: ip link del tun0 без него не проходит" >&2
    exit 1
fi

LOG=/tmp/ladder-$MODE.log
"$ADB" logcat -c
"$ADB" logcat -v time -s Anemia >"$LOG" 2>&1 &
LOGGER=$!

before=$("$ADB" shell ip -o link show tun0 2>/dev/null | tr -d '\r' | awk -F: '{print $1}' | tr -d ' ')
# Пид интерфейса. Лестница живёт в UI-процессе (широковещание отказа принимает
# его BroadcastReceiver), поэтому перезапуск или `adb install` посреди прогона
# убивает эпизод — и это не отказ лестницы, а испорченный прогон.
ui_before=$("$ADB" shell pidof app.anemia 2>/dev/null | tr -d '\r' | tr -d ' ')
echo "→ рву tun0 (был индексом $before), режим $MODE"

restore() {
    [[ "$MODE" == "hold" ]] || return 0
    "$ADB" shell svc wifi enable >/dev/null 2>&1
    "$ADB" shell svc data enable >/dev/null 2>&1
    echo "↩ линк включён обратно"
}
trap 'restore; kill $LOGGER 2>/dev/null' EXIT
"$ADB" shell ip link del tun0 >/dev/null 2>&1 || { echo "✗ не удалось снять интерфейс" >&2; exit 1; }

# Режим `stop`: посреди эпизода нажимается плитка QS (та же ветка, что и
# `SessionStarter.stop()`), и после этого туннель обязан НЕ вернуться. Это
# ровно тот случай, который лестница раньше ломала: широковещание об остановке
# не имело признака, отложенная ступенька оставалась вооружённой и поднимала
# соединение через секунду после «Отключить».
if [[ "$MODE" == "stop" ]]; then
    armed=0
    for _ in $(seq 1 24); do
        sleep 0.5
        if grep -qE 'Anemia +\([ 0-9]+\): fail:' "$LOG"; then armed=1; break; fi
    done
    if (( armed == 0 )); then
        echo "✗ обрыва в логе не дождались — останавливать было нечего"
        kill $LOGGER 2>/dev/null
        exit 1
    fi
    echo "→ эпизод идёт, тапаю плитку (SessionActivity)"
    "$ADB" shell am start -n app.anemia/.ui.SessionActivity >/dev/null 2>&1
    sleep 2
    stopped=$(grep -cE 'Anemia +\([ 0-9]+\): connect ' "$LOG" || true)
    notes=$("$ADB" shell dumpsys notification --noredact 2>/dev/null | tr -d '\r' | grep -c 'NotificationRecord.*app.anemia' || true)
    echo "  остановка принята (уведомлений: ${notes:-?}), попыток на этот миг: $stopped"
    sleep 25
    later=$(grep -cE 'Anemia +\([ 0-9]+\): connect ' "$LOG" || true)
    back=$("$ADB" shell ip -o link show tun0 2>/dev/null | tr -d '\r' | head -1)
    if [[ -n "$back" ]] || (( later > stopped )); then
        echo "✗ туннель воскрес после остановки: попыток было $stopped, стало $later"
        fail=1
    else
        echo "✓ остановка плиткой погасила эпизод: $(plural "$later" попытка попытки попыток) за весь прогон, tun0 не поднят"
    fi
    kill $LOGGER 2>/dev/null
    echo "лог: $LOG"
    exit $fail
fi

start=$SECONDS
during=0
if [[ "$MODE" == "hold" ]]; then
    "$ADB" shell svc data disable >/dev/null 2>&1
    "$ADB" shell svc wifi disable >/dev/null 2>&1
    sleep "$HOLD_OFF_SECONDS"
    # Сколько ступенек израсходовалось, пока линка не было. Движок-то поднимает
    # туннель и без подложки (`establish()` проходит), так что «попыток не было»
    # — единственный честный признак того, что лестница встала в паузу, а не
    # пережигает попытки в пустую.
    during=$(grep -cE 'Anemia +\([ 0-9]+\): connect ' "$LOG" || true)

    restore
    start=$SECONDS
fi

tun_back=""
while (( SECONDS - start < DEADLINE )); do
    if [[ -n "$("$ADB" shell ip -o link show tun0 2>/dev/null | tr -d '\r')" ]]; then
        tun_back=$(( SECONDS - start )); break
    fi
    sleep 1
done


# Что при этом сказал сервис. Отметка «fail:» — единственный наблюдаемый момент
# широковещания об обрыве: экран обновляется в тот же миг, но снаружи это не
# увидеть.
fails=$(grep -cE 'Anemia +\([ 0-9]+\): fail:' "$LOG" || true)
# Паузы «нет линка» считаем всегда: в режиме drop они тоже могут быть (например,
# когда линк мигает), и без них время возврата выглядит необъяснимым.
holds=$(grep -cE 'Anemia +\([ 0-9]+\): hold: ' "$LOG" || true)
tries=$(grep -cE 'Anemia +\([ 0-9]+\): connect ' "$LOG" || true)
masking=$(grep -oE 'connect .* with masking [a-zA-Z]+' "$LOG" | tail -1 || true)

echo "  отказов: $fails, пауз «нет линка»: ${holds:-0}, $(plural "$tries" попытка попытки попыток) (из них без линка: $during)"
echo "  ${masking:-маскирование не наблюдаемо}"

if [[ "$MODE" == "hold" ]]; then
    if [[ $during -gt 0 ]]; then
        echo "✗ ступенек, израсходованных без линка: $during — лестница должна встать в паузу (Step.Hold), а не сжигать попытки"
        fail=1
    elif [[ ${holds:-0} -eq 0 ]]; then
        echo "✗ пауз в логе нет: либо лестница не сочла линк пропавшим, либо сборка без Step.Hold"
        fail=1
    elif [[ $tries -eq 0 ]]; then
        echo "✗ и после возвращения линка не было ни одной попытки"
        fail=1
    else
        echo "✓ без линка попыток не было, после возврата сети лестница пошла с первой ступеньки"
    fi
fi


if [[ -z "$tun_back" ]]; then
    echo "✗ туннель не вернулся за ${DEADLINE} с — лестница не сработала"
    fail=1
elif (( tun_back > 0 )); then
    echo "✓ tun0 поднят сам через ${tun_back} с (индекс было $before)"
    tun_reported=1
else
    # В режиме `hold` это не успех лестницы: движок поднимает туннель и без
    # подложки, поэтому интерфейс мог ни на секунду не исчезать.
    echo "= tun0 уже был поднят: establish() проходит и без подложки"
fi
if [[ -n "${tun_back:-}" ]] && (( tun_back > 0 )); then
    # Обрыв обязан быть заявлен как обрыв: dropped=false означало бы, что
    # сервис посчитал это отказом ещё не поднявшегося подключения, и экран
    # не начал бы лестницу вовсе.
    if grep -qE 'fail: .*dropped=true' "$LOG"; then
        echo "✓ отказ заявлен как обрыв живой сессии (dropped=true)"
    else
        echo "✗ в logcat нет отметки fail: с dropped=true — экран не завёл бы лестницу"
        fail=1
    fi
fi

ui_after=$("$ADB" shell pidof app.anemia 2>/dev/null | tr -d '\r' | tr -d ' ')
if [[ -z "$ui_after" ]]; then
    echo "✗ прогон недействителен: интерфейс (app.anemia) умер посреди замера — лестница живёт в его BroadcastReceiver, и ниже стояли бы вердикты о мёртвом процессе"
    fail=1
elif [[ "$ui_after" != "$ui_before" ]]; then
    echo "✗ прогон недействителен: интерфейс перезапустили (был $ui_before, стал $ui_after) — обычно это чужой adb install посреди прогона"
    fail=1
else
    echo "  интерфейс жил весь прогон (pid $ui_after)"
fi

echo "лог: $LOG"
exit $fail
