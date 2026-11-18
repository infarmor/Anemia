package app.anemia.ui

import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class DiagnosticsReportTest {
    @get:Rule
    val files = TemporaryFolder()

    @Test
    fun reportKeepsOnlyRecognizedEventsWithoutRawDetails() {
        val log = files.newFile().apply {
            writeText(
                """
                [Anemia] xray started
                private configuration: vless://fake-token@private.example
                [Anemia] health check failed: dial tcp 192.0.2.1:443
                [Error] outbound rejected https://private.example/?token=secret
                """.trimIndent(),
            )
        }

        assertEquals(
            listOf("Xray запущен", "Проверка туннеля не прошла", "Ошибка движка"),
            publicEngineEvents(log),
        )
    }

    @Test
    fun reportKeepsOnlyTheMostRecentTwentyEvents() {
        val log = files.newFile().apply {
            writeText("[Anemia] xray started\n" + "[Warning] old warning\n".repeat(20) +
                "[Anemia] xray stopped\n")
        }

        assertEquals(List(19) { "Предупреждение движка" } + "Xray остановлен", publicEngineEvents(log))
    }
}
