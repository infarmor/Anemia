package app.anemia.vpn

import app.anemia.core.TrafficCounters
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Какое показание AmneziaWG имеет право стать базовой линией (`AwgReading`).
 * Тестует ровно то, на устройстве чего не увидеть: нулевое показание движок
 * выдаёт не «когда умер», а «когда сорвался один `IpcGet`», и пока он жив и
 * называет себя `awg`, проверить это можно только здесь.
 */
class AwgReadingTest {

    private val keys = emptyList<String>()

    @Test fun `живое показание принимается`() {
        assertNull(AwgReading.refusal("awg", keys, TrafficCounters(up = 5_000, down = 800), null))
        assertNull(
            AwgReading.refusal(
                "awg", keys,
                TrafficCounters(up = 6_000, down = 900),
                TrafficCounters(up = 5_000, down = 800),
            ),
        )
    }

    @Test fun `нулевое показание базовой линией не становится`() {
        // `awgTraffic` на сорвавшемся `IpcGet` отвечает `(0, 0, 0)`, сохранив и
        // `engine = "awg"`, и все ключи: страж «движок назвал себя» его ловит
        // только по нулям.
        assertNotNull(AwgReading.refusal("awg", keys, TrafficCounters(0, 0), null))
        assertNotNull(
            AwgReading.refusal("awg", keys, TrafficCounters(0, 0), TrafficCounters(5_000, 800)),
        )
    }

    @Test fun `отмотка счётчиков — не связка одного рана`() {
        assertNotNull(
            AwgReading.refusal("awg", keys, TrafficCounters(100, 900), TrafficCounters(5_000, 800)),
        )
        assertNotNull(
            AwgReading.refusal("awg", keys, TrafficCounters(5_000, 10), TrafficCounters(5_000, 800)),
        )
        // Рост только в одном направлении — это нормально.
        assertNull(
            AwgReading.refusal("awg", keys, TrafficCounters(5_001, 800), TrafficCounters(5_000, 800)),
        )
    }

    @Test fun `движок отчитался не собой — показание чужое`() {
        assertNotNull(AwgReading.refusal("", keys, TrafficCounters(5_000, 800), null))
        assertNotNull(AwgReading.refusal("xray", keys, TrafficCounters(5_000, 800), null))
    }

    @Test fun `ответ другой схемы не принимается`() {
        assertNotNull(AwgReading.refusal("awg", listOf("up", "down"), TrafficCounters(5_000, 800), null))
        assertNotNull(AwgReading.refusal("awg", listOf("down"), TrafficCounters(5_000, 800), null))
    }

    @Test fun `молчание телефона — не отказ, а то же самое показание`() {
        // Идентичное предыдущему показание принимается: «ничего не отправлено»
        // различает `TunnelHealth.counters` (там молчание), а не этот страж.
        assertNull(
            AwgReading.refusal("awg", keys, TrafficCounters(5_000, 800), TrafficCounters(5_000, 800)),
        )
    }

    @Test fun `причина отказа называется словами`() {
        assertEquals(
            "оба счётчика нулевые",
            AwgReading.refusal("awg", keys, TrafficCounters(0, 0), null),
        )
        assertEquals(
            "движок отчитался не собой: «»",
            AwgReading.refusal("", keys, TrafficCounters(1, 1), null),
        )
    }
}
