package app.anemia.core

import java.io.File
import java.io.IOException
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.nio.file.attribute.PosixFilePermission

/**
 * Файл состояния рядом с приложением — порт `StatePersistence` из
 * `Sources/LoaderCore/Persistence.swift`.
 *
 * Формат документа делает [StateCodec], здесь только файловая часть: чтение без
 * исключений, страховка перед тем, как молча потерять записи, и атомарная
 * запись. Различие с Swift одно: JSON пишется компактно, а не `prettyPrinted`
 * (байт в байт `state.json` между платформами не сверяется — `verify-state.sh`
 * перечитывает записанное Kotlin'ом Swift-декодером).
 */
class StatePersistence(
    val file: File,
    /** Метка в имени страховки; передаётся отдельно, чтобы это мог закрепить тест. */
    private val clock: () -> Long = System::currentTimeMillis,
) {
    /**
     * Прочитать состояние. Нет файла, не читается, не декодируется — пустое
     * состояние: бросать здесь нельзя, после этого приложение не запустится.
     * Отсутствующий файл — не испорченный, поэтому `decoded = true`: жаловаться
     * и страховаться не с чего.
     */
    fun load(): LoadedState {
        // Никакой уборки «осколков» при чтении: читающий не знает, чей временный
        // файл живой. Два процесса одного приложения (интерфейс и `:vpn`)
        // пересекаются здесь постоянно, и уборка съедает чужую незавершённую
        // запись — проверено гонкой save/load. Осколок переживает процесс, но
        // он 0600 и в каталоге приложения.
        val raw = try {
            file.readBytes()
        } catch (error: Exception) {
            // Каталог вместо файла, EACCES, удалённый носитель — всё это
            // «состояния нет», и ни одно из них не повод портить то, что на
            // диске, пустой записью.
            return LoadedState(PersistedState(), decoded = true, droppedEntries = false)
        }
        val loaded = StateCodec.load(decode(raw))
        // Молча потерять список серверов хуже, чем оставить лишнее на диске: о
        // потере сообщает сравнение «сколько записей в файле» с «сколько
        // размечтовалось» — см. [StateCodec.load].
        if (loaded.needsBackup) backUp(raw)
        return loaded
    }

    /**
     * `JSONDecoder` Foundation читает документ в любой из четырёх кодировок,
     * угадывая её по BOM (проверено: UTF-16LE состояние размечтовывается и на
     * Mac, и на iPhone). `String(raw, UTF_8)` из такого текста делает мусор, а
     * мусор — это «магазин испорчен», страховка и пустой список серверов
     * вместо ровно того же состояния.
     */
    private fun decode(raw: ByteArray): String {
        fun starts(vararg bytes: Int) = raw.size >= bytes.size &&
            bytes.indices.all { raw[it].toInt() and 0xFF == bytes[it] }
        val charset = when {
            starts(0xFF, 0xFE, 0x00, 0x00) -> Charsets.UTF_32LE
            starts(0x00, 0x00, 0xFE, 0xFF) -> Charsets.UTF_32BE
            starts(0xEF, 0xBB, 0xBF) -> Charsets.UTF_8
            starts(0xFF, 0xFE) -> Charsets.UTF_16LE
            starts(0xFE, 0xFF) -> Charsets.UTF_16BE
            else -> Charsets.UTF_8
        }
        // Кодировщики Java не съедают BOM, а Foundation его не показывает:
        // без отсечения первый символ остаётся в документе, и разбор падает на
        // заведомо исправном файле.
        return String(raw, charset).removePrefix("\uFEFF")
    }

    /** Записать состояние атомарно: полфайла вместо состояния — худший исход. */
    fun save(state: PersistedState) {
        AtomicWrite.ensureDirectory(file)
        AtomicWrite.write(file, StateCodec.encode(state).toByteArray(Charsets.UTF_8))
    }

    /**
     * Копия испорченного файла. Имя — как у Swift: `state.json` теряет
     * расширение и получает `.json.corrupt-<мс>.bak`, то есть для нашего
     * магазина это `state.json.corrupt-1730000000000.bak`. Миллисекунды,
     * потому что столкновение в пределах секунды затёрло бы более раннюю
     * страховку.
     */
    private fun backUp(raw: ByteArray) {
        val backup = File(file.parentFile, "${backupStem()}.corrupt-${clock()}.bak")
        // Это единственное, что стоит между человеком и потерей списка
        // серверов, поэтому сбой файловой системы не должен пропускать
        // страховку: если атомарный перенос не вышел, пишем как умеют.
        try {
            AtomicWrite.write(backup, raw)
        } catch (error: Exception) {
            // Страховка важнее аккуратности: если перенос не вышел (каталог на
            // чужом томе, SELinux), пишем прямо — полкопии лучше, чем ни одной.
            runCatching { backup.writeBytes(raw) }
        }
        pruneCorruptBackups()
    }

    /**
     * Покоившийся вечно магазин роняет новую страховку на каждом запуске — для
     * необслуживаемого устройства это бесконечный мусор. Оставляем три самых
     * свежих; сортировка по имени работает, пока разряд метки не изменился.
     * Каталоги с таким именем не считаются: их `delete()` не возьмёт, и они
     * вечно держали бы место в «трёх лучших».
     */
    private fun pruneCorruptBackups(kept: Int = 3) {
        val directory = file.parentFile ?: return
        val prefix = "${backupStem()}.corrupt-"
        val stale = (directory.listFiles { entry ->
            entry.isFile && entry.name.startsWith(prefix) && entry.name.endsWith(".bak")
        } ?: emptyArray()).sortedByDescending { it.name }.drop(maxOf(0, kept))
        for (staleFile in stale) runCatching { staleFile.delete() }
    }

    /**
     * Основание имени страховки. Swift делает `deletingPathExtension()` и
     * возвращает расширение в самом суффиксе: `state.json` → `state.json`,
     * а файл без расширения или с ведущей точкой (`.hidden`) остаётся как есть
     * — `deletingPathExtension` их не трогает.
     */
    private fun backupStem(): String {
        val name = file.name
        val dot = name.lastIndexOf('.')
        val stem = if (dot <= 0) name else name.substring(0, dot)
        return "$stem.json"
    }
}

/**
 * Запись файла через временный файл с уникальным именем: два писателя в одну
 * миллисекунду не должны столкнуться в одном временном файле — иначе один из
 * них переименует чужую половину записанных байтов.
 *
 * Этим пользуется [StatePersistence.save] для `state.json`, и те же правила
 * нужны соседним файлам приложения (`traffic.json`, `Anemia.anemia`):
 * полдокумента вместо документа здесь так же плохо, как полсписка серверов.
 */
object AtomicWrite {
    /** Каталог обязан существовать до временного файла: `createTempFile` в
     * несуществующем каталоге бросает то, что пользователь прочтёт как «не
     * сохранилось». */
    fun ensureDirectory(target: File) {
        val directory = target.parentFile
        if (directory != null && !directory.isDirectory && !directory.mkdirs()) {
            throw IOException("Не удалось создать каталог ${directory.path}")
        }
    }

    fun write(target: File, bytes: ByteArray) {
        val temporary = File.createTempFile("${target.name}.", ".tmp", target.parentFile)
        try {
            temporary.writeBytes(bytes)
            privatePermissions(temporary)
            moveIntoPlace(temporary, target)
        } catch (error: Exception) {
            runCatching { temporary.delete() }
            throw error
        }
    }

    fun moveIntoPlace(source: File, target: File) {
        try {
            Files.move(source.toPath(), target.toPath(), StandardCopyOption.ATOMIC_MOVE)
        } catch (error: AtomicMoveNotSupportedException) {
            // Файловая система без атомарного переноса: лучше ошибка, чем
            // испарившееся состояние — Swift в этом месте тоже не урезает файл
            // на месте.
            throw IOException("Атомарная запись невозможна: ${error.message}")
        }
    }

    /**
     * 0600. Это не паритет с iOS, а ужесточение: `.atomic` в Foundation права
     * не меняет (замерено — свежий файл выходит 0644), а в `state.json` лежат
     * приватные ключи; у соседних файлов то же основание, только слабее. На
     * Android каталог приложения и так 0700, так что это второй эшелон защиты —
     * но дешёвый.
     */
    fun privatePermissions(target: File) {
        runCatching {
            Files.setPosixFilePermissions(
                target.toPath(),
                setOf(PosixFilePermission.OWNER_READ, PosixFilePermission.OWNER_WRITE),
            )
        }
    }
}
