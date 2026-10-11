package app.anemia.data

import app.anemia.core.AtomicWrite
import app.anemia.core.TrafficLedger
import java.io.File
import java.util.TimeZone
import java.util.UUID

/**
 * Сколько прошло через туннель — порт `iOS/Anemia/TrafficStats.swift`: отсчёты
 * живого движка в [TrafficLedger], ряды дней и серверов на диске
 * (`traffic.json`, тот же документ, что читает Swift — см.
 * `Scripts/verify-traffic.sh`).
 *
 * Пишет один процесс — `:vpn`, потому что только он снимает счётчики. Экран
 * файл читает. На iOS магазин один на приложение и этот вопрос не возникал;
 * здесь второй писатель со своей копией молча откатил бы чужие минуты, отсюда
 * и «сбросить статистику» командой сервису, пока туннель жив
 * (`AnemiaVpnService.EXTRA_RESET_TRAFFIC`), а не записью из интерфейса.
 */
class TrafficStore(
    private val file: File,
    private val now: () -> Double = { System.currentTimeMillis() / 1000.0 },
    private val zone: () -> TimeZone = { TimeZone.getDefault() },
) {
    private val monitor = Any()
    private var ledger = load()

    /** `Date.distantPast`: первая запись обязана состояться, а не ждать получаса. */
    private var lastSaved = Double.NEGATIVE_INFINITY

    /**
     * Один отсчёт счётчиков текущего запуска движка. `runStartedAt` — время
     * старта именно этого запуска: ряды складываются по разнице, и смешать их
     * с прошлым прогоном значит записать его остатки заново.
     */
    fun record(
        runStartedAt: Double,
        received: Long,
        sent: Long,
        server: Pair<UUID, String>?,
    ) = synchronized(monitor) {
        val at = now()
        ledger.record(runStartedAt, received, sent, server, at, zone())
        if (at - lastSaved > SAVE_AFTER_SECONDS) saveLocked(at)
    }

    /** Движок встал: следующая связка отсчётов начинает новую сессию. */
    fun stopped() = synchronized(monitor) {
        ledger.stopped()
        saveLocked(now())
    }

    /**
     * Серверов, которых больше нет в списке, в «топе» быть не должно — то же
     * правило, что `forgetServers` на iOS. `live` обязан быть непустым: пустой
     * список у нас означает «не прочитали», а не «всё удалили».
     */
    fun forgetExcept(live: Set<UUID>) = synchronized(monitor) {
        val stale = ledger.servers.keys - live
        if (stale.isEmpty()) return@synchronized
        ledger.forget(stale)
        saveLocked(now())
    }

    /**
     * «Сбросить статистику» при живом туннеле — сюда (см. `EXTRA_RESET_TRAFFIC`):
     * очищается и ряд в памяти, и файл, иначе ближайшая запись вернула бы
     * удалённые минуты из кэша. `lastRun` остаётся, как у iOS: следующая связка
     * отсчётов идёт из той же сессии движка.
     */
    fun reset() = synchronized(monitor) {
        ledger.reset()
        saveLocked(now())
    }

    private fun load(): TrafficLedger =
        runCatching { TrafficLedger.fromJson(file.readText(Charsets.UTF_8)) }.getOrNull()
            ?: TrafficLedger()

    private fun saveLocked(at: Double) {
        lastSaved = at
        runCatching {
            AtomicWrite.ensureDirectory(file)
            AtomicWrite.write(file, ledger.toJson().toByteArray(Charsets.UTF_8))
        }.onFailure {
            // Без строки в логе «статистика не пишется» выглядело бы как
            // «трафика не было».
            android.util.Log.w(TAG, "traffic.json не сохранился: ${it.message}")
        }
    }

    companion object {
        private const val TAG = "Anemia"
        const val FILE_NAME = "traffic.json"

        /** Тот же потолок частоты записи, что у iOS. */
        private const val SAVE_AFTER_SECONDS = 30.0

        /**
         * Что показать на экране: файл читается целиком, своего кэша нет —
         * иначе после чужого сброса интерфейс держал бы старые цифры.
         */
        fun snapshot(
            file: File,
            now: Double = System.currentTimeMillis() / 1000.0,
            zone: TimeZone = TimeZone.getDefault(),
        ): Snapshot = snapshot(read(file), now, zone)

        /** Ряд с диска; пустой или испорченный файл — пустой ряд, не отказ. */
        fun read(file: File): TrafficLedger = runCatching {
            TrafficLedger.fromJson(file.readText(Charsets.UTF_8))
        }.getOrNull() ?: TrafficLedger()

        /**
         * Снимок из готового ряда. Отдельно — чтобы первый кадр экрана не
         * читал диск: `traffic.json` переписывает другой процесс, и разбор его
         * в композиции был бы тем самым «не делать I/O на главной нити», что
         * запрещает цикл обновления ниже.
         */
        fun snapshot(
            ledger: TrafficLedger,
            now: Double = System.currentTimeMillis() / 1000.0,
            zone: TimeZone = TimeZone.getDefault(),
        ): Snapshot = Snapshot(
            today = ledger.today(now, zone),
            month = ledger.month(now, zone),
            days = ledger.recentDays(RECENT_DAYS, now, zone),
            top = ledger.topServers.take(TOP_SERVERS),
        )

        const val RECENT_DAYS = 14
        const val TOP_SERVERS = 8
    }

    /** Снимок для отрисовки: ряды уже посчитаны, файл больше не нужен. */
    data class Snapshot(
        val today: TrafficLedger.Day,
        val month: TrafficLedger.Day,
        val days: List<TrafficLedger.Day>,
        val top: List<TrafficLedger.ServerTotal>,
    )
}
