package app.anemia.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.util.UUID
import java.util.concurrent.Callable
import java.util.concurrent.Executors

class SubscriptionDeviceIdTest {
    @get:Rule val files = TemporaryFolder()

    @Test
    fun concurrentReadersAndLaterInstancesSeeOnePersistentUuid() {
        val file = File(files.root, "subscription-hwid")
        val executor = Executors.newFixedThreadPool(4)
        val values = try {
            executor.invokeAll(List(12) { Callable { SubscriptionDeviceId(file).get() } })
                .map { it.get() }
        } finally {
            executor.shutdown()
        }
        val distinct = values.distinct()
        val id = distinct.single()
        assertNotNull(id)
        assertTrue(id!!.matches(Regex("[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}")))
        assertEquals(4, UUID.fromString(id).version())
        assertEquals(id, SubscriptionDeviceId(file).get())
        assertNotEquals(id, SubscriptionDeviceId(File(files.root, "other-installation")).get())
    }

    @Test
    fun damagedIdentifierIsNotSilentlyReplaced() {
        val file = files.newFile("subscription-hwid").apply { writeText("invalid stored identifier") }
        assertNull(SubscriptionDeviceId(file).get())
        assertEquals("invalid stored identifier", file.readText())
    }
}
