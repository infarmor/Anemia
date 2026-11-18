package app.anemia.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL

class SubscriptionFetcherTest {
    @Test
    fun sendsIdentityOnOriginalHttpsOriginAndDropsItPermanentlyAfterCrossOrigin() {
        val server = Requests(
            Reply.redirect("https://PANEL.example:443/subscription"),
            Reply.redirect("https://cdn.example/subscription"),
            Reply.redirect("https://panel.example/final"),
            Reply(200),
        )
        val response = server.fetch("https://panel.example/start")

        assertEquals(200, response.status)
        assertEquals(listOf(HWID, HWID, null, null), server.headers("x-hwid"))
        assertEquals(listOf("Android", "Android", null, null), server.headers("x-device-os"))
        assertEquals(List(4) { SubscriptionFetcher.USER_AGENT }, server.headers("User-Agent"))
    }

    @Test
    fun nonDefaultPortIsAnotherOrigin() {
        val server = Requests(Reply.redirect("https://panel.example:8443/next"), Reply(200))
        server.fetch("https://panel.example/start")
        assertEquals(listOf(HWID, null), server.headers("x-hwid"))
    }

    @Test
    fun httpAndItsHttpsUpgradeDoNotSendOrGenerateAnIdentifier() {
        val server = Requests(Reply.redirect("https://panel.example/secure"), Reply(200))
        val response = server.fetch("http://panel.example/start") {
            throw AssertionError("the provider must not be called for HTTP")
        }
        assertEquals("stored server data", response.body)
        assertEquals(listOf(null, null), server.headers("x-hwid"))
        assertEquals(listOf(null, null), server.headers("x-device-os"))
    }

    @Test
    fun httpsDowngradeIsStillBlocked() {
        val server = Requests(Reply.redirect("http://panel.example/not-secure"))
        val failure = assertThrows(SubscriptionFetcher.FetchError::class.java) {
            server.fetch("https://panel.example/start")
        }
        assertEquals("Fetch failed: redirect from https to http", failure.message)
        assertEquals(listOf(HWID), server.headers("x-hwid"))
    }

    @Test
    fun modernAndLegacyDenialHeadersAreHandledBeforeReadingBody() {
        for (header in listOf("X-Hwid-Max-Devices-Reached", "x-hwid-limit")) {
            val server = Requests(Reply(200, mapOf(header to listOf("false", " TrUe "))))
            val failure = assertThrows(SubscriptionFetcher.FetchError::class.java) {
                server.fetch("https://panel.example")
            }
            assertTrue(failure.message.orEmpty().contains("Достигнут лимит устройств"))
            assertFalse(server.connections.single().bodyRead)
        }
    }

    @Test
    fun missingIdTakesPrecedenceOverLegacyLimitInNonSuccessResponse() {
        val server = Requests(Reply(404, mapOf(
            "x-hwid-limit" to listOf("true"),
            "X-HWID-Not-Supported" to listOf("TRUE"),
        )))
        val failure = assertThrows(SubscriptionFetcher.FetchError::class.java) {
            server.fetch("https://panel.example")
        }
        assertTrue(failure.message.orEmpty().contains("не получил идентификатор"))
        assertFalse(server.connections.single().bodyRead)
    }

    @Test
    fun falseFlagsDoNotPreventNormalSubscriptions() {
        val server = Requests(Reply(200, mapOf(
            "x-hwid-active" to listOf("true"),
            "x-hwid-limit" to listOf("false"),
            "x-hwid-not-supported" to listOf("1"),
        )))
        val response = server.fetch("https://panel.example")

        assertEquals(200, response.status)
        assertEquals("stored server data", response.body)
    }

    @Test
    fun requestExceptionsDoNotRevealTokenOrIdentifier() {
        val server = Requests(Reply(200, bodyError = IOException("token=secret hwid=$HWID")))
        val failure = assertThrows(SubscriptionFetcher.FetchError::class.java) {
            server.fetch("https://panel.example")
        }
        assertEquals("Fetch failed: IOException", failure.message)
    }

    private class Requests(vararg replies: Reply) {
        private val replies = ArrayDeque(replies.toList())
        val connections = mutableListOf<FakeConnection>()

        fun fetch(url: String, deviceId: () -> String? = { HWID }): SubscriptionFetcher.Response =
            SubscriptionFetcher.fetch(url, deviceId, elapsedMs = { 0L }) {
                FakeConnection(it, replies.removeFirst()).also(connections::add)
            }

        fun headers(name: String): List<String?> = connections.map { it.getRequestProperty(name) }
    }

    private data class Reply(
        val status: Int,
        val headers: Map<String, List<String>> = emptyMap(),
        val bodyError: IOException? = null,
    ) {
        companion object {
            fun redirect(url: String) = Reply(302, mapOf("location" to listOf(url)))
        }
    }

    private class FakeConnection(url: URL, private val reply: Reply) : HttpURLConnection(url) {
        var bodyRead = false
            private set

        override fun connect() = Unit
        override fun disconnect() = Unit
        override fun usingProxy() = false
        override fun getResponseCode() = reply.status
        override fun getHeaderFields() = reply.headers
        override fun getContentLengthLong() = -1L
        override fun getErrorStream(): InputStream = inputStream
        override fun getInputStream(): InputStream {
            bodyRead = true
            reply.bodyError?.let { throw it }
            return ByteArrayInputStream("stored server data".toByteArray())
        }
    }

    private companion object {
        const val HWID = "05F4C813-982D-4AD4-8C95-9D869774AF6C"
    }
}
