# `:core` — порт `Sources/LoaderCore`

Чистый Kotlin, без Android-зависимостей: тогда тесты гоняются на JVM за
секунды, а golden-сверка конфигов не требует эмулятора.

## Порядок переноса

Сначала то, без чего туннель не поднять, и то, что легче всего проверить
сравнением с текущим iOS/macOS-JSON:

| Файл сейчас | Что в нём важного | Как проверять |
|---|---|---|
| `Models.swift` | `ProxyServer`, `ProxyKind`, `MaskingProfile`, `SplitTunnelRules` | поля и JSON-ключи один в один: `SyncBundle` читает файлы, созданные Mac и iPhone |
| `ShareLinkParser.swift` | `vless://`, `vmess://`, `trojan://`, `ss://`, `hy2://`, `amnezia://`, `wg://` | `Tests/LoaderCoreTests/ShareLinkParserTests.swift` |
| `SubscriptionParser.swift` | base64-простыня, markdown-подписка, дедупликация | те же корпуса ссылок |
| `XrayConfigBuilder.swift` | JSON Xray: inbound `tun`, Reality, masking, DoH | сравнение байт-в-байт с эталоном, который сейчас пишет iOS |
| `AmneziaWG.swift` | UAPI-скрипт, `tunnelIPv4`, разбор конфига | то же + живой сервер |
| `SplitTunnelParser.swift` | домены, CIDR, «зона .ru» | список исключённых маршрутов |
| `DirectResolver.swift`, `LatencyProbe.swift` | пинг TCP/TLS/ICMP, `getaddrinfo` вне пула | замеры на одном хосте, ±10 % |
| `ServerScoring.swift`, `LearnedMasking.swift` | рейтинг, подобранная маскировка по сети | прогон истории пингов |
| `TrafficLedger.swift` | дневной трафик и время «в сети» | синтетические сутки |
| `SubscriptionInfo.swift` | заголовки панелей: остаток, срок | корпуса заголовков 3x-ui/Marzban |
| `SyncBundle.swift` | `.anemia`: DEFLATE + base64url, слияние | файл, собранный Mac, должен импортироваться |
| `AntiCensorship.swift`, `Base64.swift`, `Persistence.swift` | маскировки, base64url, состояние на диске | round-trip |

Не переносится: `Kxc*` (CoreML — см. риск 3 в `../README.md`), всё, что
трогает `NetworkExtension`/`UIKit`.

## Правила переноса, чтобы не потерять найденные баги

- Границы форматирования чисел (999 против 1024, отрицательный трафик,
  `Int64` на длинной сессии) — переносим вместе с тестами, которые уже есть
  в `Tests/LoaderCoreTests/`, а не «на глаз».
- Таймауты у каждого сетевого вызова. В iOS-коде это рождало зависания
  (`LeakCheck` без `timeoutInterval` — две минуты спиннера, `getaddrinfo` на
  кооперативном пуле — висящее расширение). В Kotlin-порте пусть сразу будут.
- Ничего не считаем «проверенным», если запрос не ответил: «нет ответа» и
  «утечек нет» — разные состояния (см. `LeakChecker.verdict` на iOS).
- Парсинг пользовательских строк не должен уметь падать: в Swift это
  `dropFirst`/`prefix` на границах, в Kotlin — `substring` без проверки
  длины. Тесты на пустой вход, обрезанную ссылку и мусор обязательны.
