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
PYTHON="${PYTHON:-python3}"
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

SNAP=/tmp/ladder-$MODE.log
# Снимок лога по требованию: фоном `adb logcat` держать нельзя — он переживает
# не каждый чужой `adb kill-server`, а пустой файл скрипт прочёл бы как
# «лестница молчала».
logsnap() { "$ADB" logcat -d -v time -s Anemia 2>/dev/null | tr -d '\r' >"$SNAP"; }
# Сколько не-VPN сетей ещё зарегистрировано — то же, что видит экран.
count_agents() { "$ADB" shell "dumpsys connectivity 2>/dev/null | grep -cE 'ni\\{(WIFI|MOBILE|ETHERNET) CONNECTED'" 2>/dev/null | tr -d '\r' | tail -1; }
# Файл прошлого прогона на том же пути: без обнуления его строки сойдут за
# доказательства этого (и «лестница держится», и «лестница молчит» — что угодно).
: >"$SNAP"
"$ADB" logcat -c

before=$("$ADB" shell ip -o link show tun0 2>/dev/null | tr -d '\r' | awk -F: '{print $1}' | tr -d ' ')
# Пид интерфейса. Лестница живёт в UI-процессе (широковещание отказа принимает
# его BroadcastReceiver), поэтому перезапуск или `adb install` посреди прогона
# убивает эпизод — и это не отказ лестницы, а испорченный прогон.
ui_before=$("$ADB" shell pidof app.anemia 2>/dev/null | tr -d '\r' | tr -d ' ')
echo "→ рву tun0 (был индексом $before), режим $MODE"

# Линк гасится в `hold` и в `stop`; включать обратно надо в обоих, иначе
# прогон оставляет устройство без сети, а следующий режим честно доложит о
# паузах «нет линка» вместо результата.
LINK_OFF=0
restore() {
    (( LINK_OFF )) || return 0
    LINK_OFF=0
    "$ADB" shell svc wifi enable >/dev/null 2>&1
    "$ADB" shell svc data enable >/dev/null 2>&1
    echo "↩ линк включён обратно"
}
trap 'restore' EXIT
if [[ "$MODE" == "hold" || "$MODE" == "stop" ]]; then
    # «Нет линка» надо дождаться, а не предположить: `svc wifi disable` возвращает
    # управление сразу, и лестница успевает увидеть ещё живую сеть и честно
    # потратить ступеньку. Тогда `during=1` — не баг, а артефакт замера.
    "$ADB" shell svc data disable >/dev/null 2>&1
    "$ADB" shell svc wifi disable >/dev/null 2>&1
    LINK_OFF=1
    # Дефолтная сеть снимается раньше, чем система убирает регистрацию: `allNetworks`
    # ещё несколько секунд отдаёт живые capabilities, и лестница за это время
    # успевает потратить ступеньку по совершенно уважительной причине. Ждём снятия
    # регистрации и даём ей устояться.
    #
    # Оговорка, которую скрипт обязан делать вслух: `count_agents` считает
    # состояние транпорта по строкам `ni{(WIFI|MOBILE|ETHERNET) CONNECTED`, а
    # экран решает по `allNetworks` + возможности INTERNET и НЕ-VPN. Это разные
    # вопросы, и совпадают они только на этом эмуляторе: здесь у сети либо есть транспорт, либо нет. Поэтому настоящее доказательство паузы — строчка
    # `hold:` в логе приложения (её печатает сам `hasPhysicalLink`), и ниже
    # красным считается именно её отсутствие, а не число агентов.
    for _ in $(seq 1 30); do
        [[ "$(count_agents)" == "0" ]] && break
        sleep 1
    done
    sleep 2
    agents=$(count_agents)
    if [[ "${agents:-1}" != "0" ]]; then
        echo "✗ non-VPN сеть всё ещё зарегистрирована (агентов: $agents) — проверять паузу бессмысленно"
        restore
        exit 1
    fi
fi
"$ADB" shell ip link del tun0 >/dev/null 2>&1
if [[ $? -ne 0 ]]; then
    # На части прошивок снятие подложки само роняет интерфейс VPN, и `ip link del`
    # отвечает «не существует» — это не поломка замера, а тот самый случай,
    # который лестница и должна увидеть. Красным становится только случай, когда
    # интерфейс жив и приложения до него не коснулось.
    if [[ -n "$("$ADB" shell ip -o link show tun0 2>/dev/null | tr -d '\r')" ]]; then
        echo "✗ не удалось снять интерфейс, и он всё ещё поднят — проверять нечего" >&2
        exit 1
    fi
    echo "→ интерфейса уже нет (система сняла его вместе с подложкой)"
fi

# Режим `stop`: посреди эпизода нажимается плитка QS (та же ветка, что и
# `SessionStarter.stop()`), и после этого туннель обязан НЕ вернуться. Это
# ровно тот случай, который лестница раньше ломала: широковещание об остановке
# не имело признака, отложенная ступенька оставалась вооружённой и поднимала
# соединение через секунду после «Отключить».
if [[ "$MODE" == "stop" ]]; then
    # Окно должно быть широким: иначе проверка превращается в гонку с logcat,
    # который через adb ещё и с задержкой пишет. Поэтому линк уже погашен выше, лестница
    # встаёт в паузу (5 с между шагами), и именно в паузе нажимается
    # «Отключить» на экране — канонический путь «пользователь остановил».
    armed=0
    for _ in $(seq 1 40); do
        sleep 0.5
        logsnap
        grep -qE 'Anemia +\([ 0-9]+\): hold: ' "$SNAP" && { armed=1; break; }
    done
    if (( armed == 0 )); then
        echo "✗ паузы «нет линка» не дождались — ловить нечего"
        restore;         exit 1
    fi
    tap=$("$PYTHON" - "$ADB" <<'TAPI'
import re, subprocess, sys
adb = sys.argv[1]
subprocess.run([adb, "shell", "uiautomator", "dump", "/sdcard/stop.xml"], capture_output=True)
xml = subprocess.run([adb, "shell", "cat", "/sdcard/stop.xml"], capture_output=True, text=True).stdout
for m in re.finditer(r'text="([^"]*)"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', xml):
    if m.group(1) == "Отключить":
        l, t, r, b = (int(m.group(i)) for i in range(2, 6))
        print(f"{(l + r) // 2} {(t + b) // 2}")
        break
TAPI
)
    if [[ -z "$tap" ]]; then
        echo "✗ кнопки «Отключить» на экране не нашлось — прогон нечестный"
        restore;         exit 1
    fi
    echo "→ в паузе нажимаю «Отключить» (${tap})"
    "$ADB" shell input tap ${tap} >/dev/null 2>&1
    sleep 2
    notes=$("$ADB" shell dumpsys notification --noredact 2>/dev/null | tr -d '\r' | grep -c 'NotificationRecord.*app.anemia' || true)
    # Снимок ОБЯЗАН быть свежим в обеих точках. `logsnap` пишет буфер logcat в
    # один и тот же файл, и без нового снимка `later` буквально равен `stopped`:
    # сравнение `later > stopped` не краснело бы никогда, а «туннель воскрес»
    # нельзя было бы увидеть даже если он правда поднялся.
    logsnap
    stopped=$(grep -cE 'Anemia +\([ 0-9]+\): connect ' "$SNAP" || true)
    echo "  уведомлений после остановки: ${notes:-?}, попыток на этот миг: $stopped"
    if [[ "${notes:-1}" != "0" ]]; then
        echo "✗ уведомление сервиса осталось — остановка не дошла, и молчание ниже объясняется этим, а не лестницей"
        fail=1
    fi
    restore
    sleep 25
    later=$(logsnap; grep -cE 'Anemia +\([ 0-9]+\): connect ' "$SNAP" || true)
    back=$("$ADB" shell ip -o link show tun0 2>/dev/null | tr -d '\r' | head -1)
    if [[ -n "$back" ]] || (( later > stopped )); then
        echo "✗ туннель воскрес после остановки: попыток было $stopped, стало $later"
        fail=1
    else
        echo "✓ остановка в паузе погасила эпизод: $(plural "$later" попытка попытки попыток) за весь прогон, tun0 не поднят"
    fi
        echo "лог: $SNAP"
    exit $fail
fi

start=$SECONDS
during=0
holds=0
if [[ "$MODE" == "hold" ]]; then
    # Ждём именно паузу, а не просто секунды: без неё проверка «ручное
    # подключение не убивает эпизод» превращается в проверку ничего.
    for _ in $(seq 1 30); do
        sleep 0.5
        logsnap
        grep -qE 'Anemia +\([ 0-9]+\): hold: ' "$SNAP" && break
    done
    holds=$(grep -cE 'Anemia +\([ 0-9]+\): hold: ' "$SNAP" || true)
    sleep "$HOLD_OFF_SECONDS"
    # Сколько ступенек израсходовалось, пока линка не было. Движок-то поднимает
    # туннель и без подложки (`establish()` проходит), так что «попыток не было»
    # — единственный честный признак того, что лестница встала в паузу, а не
    # пережигает попытки в пустую.
    during=$(logsnap; grep -cE 'Anemia +\([ 0-9]+\): connect ' "$SNAP" || true)

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
logsnap
fails=$(grep -cE 'Anemia +\([ 0-9]+\): fail:' "$SNAP" || true)
# Паузы «нет линка» считаем всегда: в режиме drop они тоже могут быть (например,
# когда линк мигает), и без них время возврата выглядит необъяснимым.
holds=$(grep -cE 'Anemia +\([ 0-9]+\): hold: ' "$SNAP" || true)
tries=$(grep -cE 'Anemia +\([ 0-9]+\): connect ' "$SNAP" || true)
# «Где-то в логе был connect» ничего не доказывает: туннель мог поднять чужой
# тап (или вторая сессия, которая в это же время гоняет свой сценарий). Нужен
# порядок: попытка обязана идти после обрыва.
after_fail=$(awk '/Anemia .*\): fail:/ {seen=1; next} seen && /Anemia .*\): connect / {n++} END {print n+0}' "$SNAP")
masking=$(grep -oE 'connect .* with masking [a-zA-Z]+' "$SNAP" | tail -1 || true)

if [[ ! -s "$SNAP" ]]; then
    # Пустой лог — не «лестница молчала»: так выглядит устройство, которое
    # переподключили посреди замера. Вердикт по пустому файлу был бы ложью.
    echo "✗ logcat не отдал ни одной строки — прогон недействителен"
    exit 1
fi
echo "  отказов: $fails, пауз «нет линка»: ${holds:-0}, $(plural "$tries" попытка попытки попыток) (из них без линка: $during)"
echo "  ${masking:-маскирование не наблюдаемо}"

if [[ "$MODE" == "drop" ]]; then
    if [[ $after_fail -eq 0 ]]; then
        echo "✗ после обрыва не было ни одной попытки от лестницы — туннель вернулся не благодаря ей"
        fail=1
    fi
fi

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
    if grep -qE 'fail: .*dropped=true' "$SNAP"; then
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

echo "лог: $SNAP"
exit $fail
