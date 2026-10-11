package app.anemia.data

import android.content.Context
import android.content.Intent
import android.util.Log
import app.anemia.core.AtomicWrite
import java.io.File

/**
 * Обход VPN по приложениям — `Builder.addDisallowedApplication()`. Такого на
 * iOS нет физически: там «Мимо VPN» умеет быть только по адресам и доменам, а
 * здесь к списку добавляется ещё одно измерение — «кто на этом телефоне».
 *
 * Хранится отдельным файлом, а не в `SharedPreferences`, и читается заново на
 * каждом `establish()`. Причина именно межпроцессная: настройки кэшируются в
 * процессе, и живой `:vpn`, поднятый до правки списка, при переподключении
 * молча взял бы былый список — файл так не умеет. В `state.json` список тоже
 * не едет: это перечень чужих пакетов, которых у Swift-половины просто нет
 * (та же причина, что у `PanelStore` для заголовков панелей).
 */
object AppBypass {
    /** Приложение с иконкой в ленчере: именно его человек понимает под
     * «приложением», а не любой установленный пакет. */
    data class Entry(val pkg: String, val label: String)

    private const val FILE_NAME = "app-bypass.txt"
    private const val TAG = "Anemia"

    /**
     * Контекст держится статически потому, что список читает `ConfigApplier`
     * во время `establish()` — из процесса туннеля, куда контекст не передают.
     * Приложение создаёт его раньше любого подключения (`AnemiaApplication`), и
     * держится ровно `applicationContext`, а не активность.
     */
    @Volatile private var appContext: Context? = null

    fun init(context: Context) {
        appContext = context.applicationContext
    }

    /** Файл читается заново каждый раз: кэш здесь и был бы тем самым багом. */
    fun selected(): List<String> {
        val context = appContext ?: return emptyList()
        return runCatching {
            file(context).readLines(Charsets.UTF_8).map { it.trim() }.filter { it.isNotEmpty() }
        }.getOrDefault(emptyList())
    }

    /**
     * Записать список. Пакеты сортируются: файл перечитывает другой процесс, и
     * порядок обхода должен быть одним и тем же на обеих сторонах, иначе
     * `establish()` каждый раз строил бы разные маршруты.
     *
     * Причина отказа возвращается, а не глотается: непозаписанный ряд значит,
     * что галочка на экране осталась, а туннель её никогда не применит — это
     * надо увидеть, а не прочитать в logcat.
     */
    fun set(context: Context, packages: Set<String>): String? {
        val target = file(context)
        val body = packages.sorted().joinToString("\n", postfix = "\n")
        return runCatching {
            AtomicWrite.ensureDirectory(target)
            AtomicWrite.write(target, body.toByteArray(Charsets.UTF_8))
            null
        }.getOrElse {
            Log.w(TAG, "список обхода по приложениям не сохранился: ${it.message}")
            "список не сохранился: ${it.message ?: "нет причины"}"
        }
    }

    /**
     * Что показать в списке. Берутся пакеты с ленчер-иконкой
     * (`ACTION_MAIN` + `CATEGORY_LAUNCHER`) — официальный способ перечислить
     * «видимые» приложения без `QUERY_ALL_PACKAGES`, который выдал бы весь
     * каталог системы, включая служебный.
     *
     * Своего пакета здесь нет: он исключается из туннеля всегда, иначе движок
     * замкнуло бы на самого себя.
     */
    fun launchable(context: Context, selfPackage: String): List<Entry> {
        val manager = context.packageManager
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val seen = LinkedHashMap<String, Entry>()
        for (info in manager.queryIntentActivities(intent, 0)) {
            val pkg = info.activityInfo?.packageName ?: continue
            if (pkg == selfPackage || pkg in seen) continue
            val label = runCatching { info.loadLabel(manager).toString() }.getOrDefault(pkg)
            seen[pkg] = Entry(pkg, label.ifEmpty { pkg })
        }
        return seen.values.sortedWith(
            compareBy<Entry> { it.label.trim().lowercase() }.thenBy { it.pkg },
        )
    }

    private fun file(context: Context) = File(context.applicationContext.filesDir, FILE_NAME)
}
