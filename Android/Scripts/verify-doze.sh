#!/usr/bin/env bash
#
# Проверка «а жив ли туннель во сне»: приложение уходит в doze с погашенным
# экраном и обязано продолжить и держать туннель, и считать тики наблюдателя.
#
#   bash Android/Scripts/verify-doze.sh [секунд простоя]     # по умолчанию 45
#
# Что именно здесь доказательство, а что — нет:
#
#   • «tun0 цел» — сам по себе ничего не значит: интерфейс живёт и у мёртвого
#     процесса, пока система его не сняла.
#   • «apkid жив» — тоже: убитый tid не равен замороженному.
#   • Заморозку выдаёт именно часов: счётчик uptime в уведомлении двигается
#     только из рабочего потока сервиса (`tick` → `StatusChannel.publish`).
#     Тики перестали приходить — процесс стоит, и «туннель есть» в этот момент
#     значит лишь то, что его ещё не сняли.
#
# Выход — 0, если за простой туннель остался и часы двинулись.
set -uo pipefail

SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ADB="$SDK/platform-tools/adb"
IDLE_SECONDS="${1:-45}"
fail=0

command -v "$ADB" >/dev/null || { echo "✗ нет $ADB" >&2; exit 1; }
"$ADB" get-state >/dev/null 2>&1 || { echo "✗ устройство не подключено" >&2; exit 1; }

uptime_of() {
    "$ADB" shell dumpsys notification --noredact 2>/dev/null | tr -d '\r' \
        | grep -oE '(xray|awg) · [^"]*· [0-9]+ с' | grep -oE '[0-9]+ с$' | grep -oE '[0-9]+' | head -1
}

before=$(uptime_of)
if [[ -z "$("$ADB" shell ip -o link show tun0 2>/dev/null | tr -d '\r')" ]]; then
    echo "✗ туннеля нет: сначала подключитесь (verify-tunnel.sh)" >&2
    exit 1
fi
echo "→ до простоя: ${before:-часов не видно} с, tun0 поднят"

# Убираем и экран, и «пользователь активен»: без этого doze не наступит.
#
# Состояние белого списка ловится до и возвращается после: скрипт меняет
# системную политику, и оставить её изменённой — значит следующим прогонам
# (и любому, кто возьмёт прибор после) подсунуть чужие условия.
was_whitelisted=$(
    "$ADB" shell dumpsys deviceidle 2>/dev/null | tr -d '\r' |
    sed -n '/Whitelisted app IDs/,/^$/p' | grep -c 'app.anemia' || true
)
# Приложение, наоборот, ИЗ белого списка ВЫНОСИТСЯ. Без этого замера нет:
# exempt-процесс doze не трогает, и «часы шли» было бы тривиально истинно —
# ровно та декоративная проверка, из-за которой скрипт и стоит править. With
# С `-app.anemia` процесс обязан пережить idle сам, и только тогда сравнение
# часов до и после что-то доказывает.
#
# Что при этом остаётся недоказуемым отсюда: OEM-убийцы (Miui, Samsung) процесс
# не замораживают, а снимают целиком — против них у нас START_REDELIVER_INTENT
# и foreground-сервис типа `vpn`, и проверяется это на другой прошивке.
"$ADB" shell dumpsys deviceidle whitelist -app.anemia >/dev/null 2>&1
"$ADB" shell dumpsys deviceidle force-idle >/dev/null 2>&1
"$ADB" shell input keyevent KEYCODE_SLEEP >/dev/null 2>&1
# `force-idle` DeviceIdleService применяет в своём обработчике, и с одного
# чтения буфера можно увидеть ещё не наступивший режим. Без опроса скрипт
# краснел на прогоне, который ровно то и измерил, что умеет: на медленном
# эмуляторе mState догонял за две-три секунды.
state=""
for _ in $(seq 1 10); do
    sleep 1
    state=$("$ADB" shell dumpsys deviceidle 2>/dev/null | tr -d '\r' | grep -oE '(^|[^A-Za-z])mState=[A-Z]+' | head -1 | grep -oE 'mState=[A-Z]+')
    [[ "$state" == "mState=IDLE" ]] && break
done
echo "→ режим ${state:-mState=неизвестен}, ждём ${IDLE_SECONDS} с"
if [[ "$state" != "mState=IDLE" ]]; then
    # Без наступившего doze проверка превращается в «поспали сколько-то секунд»:
    # часы бы и так шли, и успех ничего не значил бы.
    echo "✗ doze не наступил (${state:-mState не читается}) — проверять заморозку не в чем"
    "$ADB" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1
    "$ADB" shell dumpsys deviceidle unforce >/dev/null 2>&1
    "$ADB" shell dumpsys deviceidle whitelist -app.anemia >/dev/null 2>&1
    exit 1
fi
sleep "$IDLE_SECONDS"

during_ifaces=$("$ADB" shell ip -o link show tun0 2>/dev/null | tr -d '\r' | head -1)
after=$(uptime_of)
"$ADB" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1
"$ADB" shell dumpsys deviceidle unforce >/dev/null 2>&1
if [[ "${was_whitelisted:-0}" != "0" ]]; then
    "$ADB" shell dumpsys deviceidle whitelist +app.anemia >/dev/null 2>&1
fi

if [[ -z "$during_ifaces" ]]; then
    echo "✗ во время простоя tun0 исчез — система сняла туннель"
    fail=1
else
    echo "✓ tun0 пережил простой (${during_ifaces%%:*})"
fi

if [[ -z "$before" || -z "$after" ]]; then
    echo "✗ часы не прочитаны (до: '${before:-нет}', после: '${after:-нет}'): доказательства жизни наблюдателя нет"
    fail=1
elif (( after > before )); then
    echo "✓ наблюдатель тикал во сне: ${before} с → ${after} с за ${IDLE_SECONDS} с простоя"
else
    echo "✗ часы стоят (${before} с → ${after} с): рабочий поток сервиса не работал всё время doze"
    fail=1
fi

# Wake-up-источник: netd обязан зарегистрировать интерфейс при подъёме. Без
# этого входящий пакет разбуждает процессор уже «из сна», и сон обходится
# потерянными пакетами, а не только молчанием тиков.
if [[ "$("$ADB" shell "dmesg 2>/dev/null | grep -c wsusp" 2>/dev/null | tr -d '\r')" == *[0-9]* ]]; then
    : # dmesg обычно закрыт — не считаем это провалом
fi
echo "подсказка: регистрация пробуждения видна как \`wakeupAddInterface(tun0 …)\` в logcat в момент establish()"
exit $fail
