package app.anemia.data

import app.anemia.core.LeakCheck
import java.util.UUID
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Экран утечек ставит галочку только там, где сравнение состоялось._gate_
 * «выход в вашей стране» — то же правило, что у `LeakCheck.findings`: по стране
 * выход ничего не прячет, и «через VPN» там сказать нечем.
 */
class LeakReportTest {
    private val server = UUID.fromString("CAFE0000-0000-0000-0000-000000000001")

    private fun report(
        exit: String?,
        direct: String?,
    ) = LeakChecker.Report(
        checkedAt = 1L,
        serverId = server,
        exit = exit?.let { LeakCheck.IPInfo(ip = "1.1.1.1", countryCode = it) },
        direct = direct?.let { LeakCheck.IPInfo(ip = "2.2.2.2", countryCode = it) },
    )

    @Test fun `выход в своей стране — сравнивать не с чем`() {
        assertTrue(report("nl", "NL").sameCountryAsHome)
    }

    @Test fun `выход в другой стране — сравнение есть`() {
        assertFalse(report("de", "NL").sameCountryAsHome)
    }

    @Test fun `без одной из сторон правила не существует`() {
        assertFalse(report(null, "NL").sameCountryAsHome)
        assertFalse(report("NL", null).sameCountryAsHome)
        assertFalse(report(null, null).sameCountryAsHome)
    }
}
