package app.anemia.core

import app.anemia.data.ProbeHistory
import app.anemia.data.ProbeStore
import java.io.File
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Ряд истории переживает и запись, и чтение: круг пишет `-1`, macOS пишет тот же
 * код отказа, а `null` в файле — чужая рука, и она обязана остаться «нет
 * ответа», а не превратиться в 0 мс.
 */
class ProbeHistoryTest {
    private val idA = UUID.fromString("AAAAAAAA-0000-0000-0000-000000000001")
    private val idB = UUID.fromString("BBBBBBBB-0000-0000-0000-000000000002")

    private fun fresh(): File = File.createTempFile("anemia-probes-", ".json").apply { delete() }

    @Test fun `отказ переживает перезапись тем же кодом`() {
        val file = fresh()
        ProbeHistory(file).save(mapOf(idA to listOf(40f, -1f, 55f)))
        assertEquals(listOf(40f, -1f, 55f), ProbeHistory(file).load().getValue(idA))
        file.delete()
    }

    @Test fun `null в файле остаётся пропуском, а не нулём`() {
        val file = fresh()
        file.writeText("""{"schema":2,"series":{"$idA":[40,null,55]}}""")
        val row = ProbeHistory(file).load().getValue(idA)
        assertEquals(3, row.size)
        assertTrue("пропуск обязан быть нечисловым", row[1].isNaN())
        assertEquals(40f, row[0], 0f)
        assertEquals(55f, row[2], 0f)
        file.delete()
    }

    @Test fun `мусор в ряду выбрасывает только этот ряд`() {
        val file = fresh()
        file.writeText("""{"schema":2,"series":{"$idA":[40,"быстро",55],"$idB":[70,80]}}""")
        val loaded = ProbeHistory(file).load()
        assertFalse("ряд со строкой внутри принимать нельзя", loaded.containsKey(idA))
        assertEquals(listOf(70f, 80f), loaded.getValue(idB))
        file.delete()
    }

    @Test fun `чужая схема не дописывается`() {
        val file = fresh()
        file.writeText("""{"schema":1,"series":{"$idA":[40,55]}}""")
        assertTrue("ряды старой методики принимаются за пустоту", ProbeHistory(file).load().isEmpty())
        file.delete()
    }

    @Test fun `потолок ряда держится с хвоста`() {
        val file = fresh()
        ProbeHistory(file).save(mapOf(idA to (1..300).map { it.toFloat() }))
        val row = ProbeHistory(file).load().getValue(idA)
        assertEquals(ProbeHistory.MAX_SAMPLES, row.size)
        assertEquals(300f, row.last(), 0f)
        // 300 записей, оставлены последние 256: первая — сорок пятая.
        assertEquals(45f, row.first(), 0f)
        file.delete()
    }
}

/** Правило слияния: что происходит, когда круг успел писать до дочитки диска. */
class ProbeStoreMergeTest {
    private val store = ProbeStore(ProbeHistory(fresh()))

    private companion object {
        fun fresh(): File = File.createTempFile("anemia-merge-", ".json")
    }

    @Test fun `история встаёт перед свежими отсчётами`() {
        assertEquals(
            listOf(10f, 20f, 30f, -1f),
            store.mergedHistory(listOf(10f, 20f), listOf(30f, -1f)),
        )
    }

    @Test fun `пустой диск не трогает ряд круга`() {
        assertEquals(listOf(30f), store.mergedHistory(emptyList(), listOf(30f)))
    }

    @Test fun `потолок режет старое, хвост круга сохраняется`() {
        val merged = store.mergedHistory((1..300).map { it.toFloat() }, listOf(900f, 901f))
        assertEquals(ProbeHistory.MAX_SAMPLES, merged.size)
        assertEquals(listOf(900f, 901f), merged.takeLast(2))
        // 302 ряда вместе, оставлены последние 256 — начиная с сорок седьмого.
        assertEquals(47f, merged.first(), 0f)
    }
}
