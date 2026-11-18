package app.anemia.data

import app.anemia.core.AtomicWrite
import java.io.File
import java.io.RandomAccessFile
import java.util.Locale
import java.util.UUID

/** One identifier per installation, outside transferable state and Android backups. */
internal class SubscriptionDeviceId(private val file: File) {
    @Volatile private var saved: String? = null

    fun get(): String? = saved ?: synchronized(lock) {
        saved ?: runCatching {
            AtomicWrite.ensureDirectory(file)
            // Ordinary refresh and Settings share this instance. The file lock also keeps
            // a second app process from registering a different ID during first launch.
            RandomAccessFile(File(file.parentFile, "${file.name}.lock"), "rw").use { lockFile ->
                lockFile.channel.lock().use {
                    if (file.exists()) {
                        val stored = file.readText(Charsets.US_ASCII)
                        val parsed = UUID.fromString(stored)
                        parsed.toString().uppercase(Locale.ROOT)
                            .takeIf { parsed.version() == 4 && it.equals(stored, ignoreCase = true) }
                    } else {
                        UUID.randomUUID().toString().uppercase(Locale.ROOT).also { id ->
                            AtomicWrite.write(file, id.toByteArray(Charsets.US_ASCII))
                        }
                    }
                }
            }
        }.getOrNull()?.also { saved = it }
    }

    private companion object {
        val lock = Any()
    }
}
