package app.anemia.data

import app.anemia.core.MaskingProfile
import app.anemia.core.ProxyProtocol
import app.anemia.core.ProxyServer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Лестница восстановления: порядок ступеней, их задержки и потолок попыток.
 * Всё это списано с `attemptReconnect` на macOS (1→2→4 с, `maxReconnects + 5`),
 * и проверяется здесь, а не золотом: золотые сверки сравнивают две реализации
 * одного алгоритма над общими фикстурами, а этот алгоритм живёт только в UI-слое
 * и работает с уже разобранным состоянием.
 *
 * Задержки в тесте — не косметика: в первом порту они уехали на единицу
 * (1 shl attempt вместо 1 shl attempt-1), и без проверки разницы в 1 с это
 * можно было не заметить совсем.
 */
class RecoveryTest {

    private fun server(name: String): ProxyServer = ProxyServer(
        name = name,
        proto = ProxyProtocol.VLESS,
        address = "10.0.2.2",
        port = 10443,
        credential = "11111111-1111-1111-1111-111111111111",
    )

    /** Один шаг: `begin` + `step`, как это делает экран на сообщение об отказе. */
    private fun climb(
        ladder: Recovery,
        current: ProxyServer?,
        profile: MaskingProfile = MaskingProfile.balanced,
        candidates: List<Pair<ProxyServer, Double?>>,
    ): Recovery.Step {
        ladder.begin(current?.id)
        return ladder.step(current, profile, candidates)
    }

    @Test fun `первая попытка повторяет тот же сервер`() {
        val ladder = Recovery()
        val a = server("🇳🇱 A")
        assertEquals(Recovery.Step.Same(1_000L), climb(ladder, a, candidates = listOf(a to null)))
    }

    @Test fun `вторая попытка поднимает маскирование на ступень`() {
        val ladder = Recovery()
        val a = server("🇳🇱 A")
        ladder.begin(a.id)
        assertEquals(Recovery.Step.Same(1_000L), ladder.step(a, MaskingProfile.balanced, listOf(a to null)))
        assertEquals(
            Recovery.Step.Escalate(MaskingProfile.maximum, 2_000L),
            climb(ladder, a, candidates = listOf(a to null)),
        )
        assertEquals(MaskingProfile.maximum, ladder.forcedProfile())
    }

    @Test fun `третья попытка уходит на соседний сервер и снимает эскалацию`() {
        val ladder = Recovery()
        val a = server("🇳🇱 A")
        val b = server("🇩🇪 B")
        climb(ladder, a, candidates = listOf(a to null, b to null))
        climb(ladder, a, candidates = listOf(a to null, b to null))
        val third = climb(ladder, a, candidates = listOf(a to null, b to null))
        assertEquals(Recovery.Step.Switch(b, 4_000L), third)
        assertNull(ladder.forcedProfile())
    }

    @Test fun `задержки идут как на macOS — 1, 2, 4 и дальше 4`() {
        val ladder = Recovery()
        val a = server("🇳🇱 A")
        val spares = (1..6).map { server("🇸🇪 S$it") to (null as Double?) }
        val delays = (1..7).map {
            when (val step = climb(ladder, a, candidates = listOf(a to null) + spares)) {
                is Recovery.Step.Hold -> step.delayMs
                is Recovery.Step.Same -> step.delayMs
                is Recovery.Step.Escalate -> step.delayMs
                is Recovery.Step.Switch -> step.delayMs
                is Recovery.Step.GiveUp -> -1L
            }
        }
        assertEquals(listOf(1_000L, 2_000L, 4_000L, 4_000L, 4_000L, 4_000L, 4_000L), delays)
    }

    @Test fun `после потолка — отказ, и он окончательный`() {
        val ladder = Recovery(maxReconnects = 3)
        val a = server("🇳🇱 A")
        val spares = (1..10).map { server("🇸🇪 S$it") to (null as Double?) }
        val candidates = listOf(a to null) + spares
        // maxReconnects + 5 = 8 попыток ещё поднимают сервис, девятая — сдаёмся.
        var current: ProxyServer = a
        repeat(8) { attempt ->
            val step = climb(ladder, current, candidates = candidates)
            assertTrue("попытка ${attempt + 1} не должна была сдаться: $step", step !is Recovery.Step.GiveUp)
            if (step is Recovery.Step.Switch) current = step.server
        }
        assertTrue(climb(ladder, current, candidates = candidates) is Recovery.Step.GiveUp)
    }

    @Test fun `российский выход не становится кандидатом`() {
        val ladder = Recovery()
        val a = server("🇳🇱 A")
        val ru = server("🇷🇺 R")
        climb(ladder, a, candidates = listOf(a to null, ru to 10.0))
        climb(ladder, a, candidates = listOf(a to null, ru to 10.0))
        assertEquals(
            Recovery.Step.GiveUp("нет рабочего сервера"),
            climb(ladder, a, candidates = listOf(a to null, ru to 10.0)),
        )
    }

    @Test fun `без запасного сервера лестница заканчивается отказом`() {
        val ladder = Recovery()
        val a = server("🇳🇱 A")
        climb(ladder, a, candidates = listOf(a to null))
        climb(ladder, a, candidates = listOf(a to null))
        // Одна ступенька эскалации уже сыграна; переключаться не на что — это
        // тот случай, ради которого убрали «не начинать лестницу на одном
        // сервере»: первые две попытки полезны и без запасного выхода.
        assertEquals(
            Recovery.Step.GiveUp("нет рабочего сервера"),
            climb(ladder, a, candidates = listOf(a to null)),
        )
    }

    @Test fun `кандидат выбирается по замеру, а немереные — последние`() {
        val ladder = Recovery()
        val a = server("🇳🇱 A")
        val slow = server("🇫🇮 Slow")
        val fast = server("🇸🇪 Fast")
        val unmeasured = server("🇳🇴 North")
        climb(ladder, a, candidates = listOf(a to null, slow to 400.0, unmeasured to null))
        climb(ladder, a, candidates = listOf(a to null, slow to 400.0, unmeasured to null))
        val candidates = listOf(a to null, slow to 400.0, fast to 50.0, unmeasured to null)
        assertEquals(
            Recovery.Step.Switch(fast, 4_000L),
            climb(ladder, a, candidates = candidates),
        )
        // Медленнее — следующий шаг, и только потом тот, о чём ещё не знаем.
        assertEquals(
            Recovery.Step.Switch(slow, 4_000L),
            climb(ladder, fast, candidates = candidates),
        )
        assertEquals(
            Recovery.Step.Switch(unmeasured, 4_000L),
            climb(ladder, slow, candidates = candidates),
        )
    }

    @Test fun `переключение идёт по истории, а не по последнему пингу`() {
        val ladder = Recovery()
        val a = server("🇳🇱 A")
        val lucky = server("🇫🇮 Lucky")
        val steady = server("🇸🇪 Steady")
        // `lucky` разово ответил быстрее, но в истории он хуже: ряды меряются
        // `rankingScore`, и лестница обязана брать исторически лучшего соседа —
        // тот же выбор, что делает кнопка «Лучший».
        val candidates = listOf(a to null, lucky to 900.0, steady to 700.0)
        climb(ladder, a, candidates = candidates)
        climb(ladder, a, candidates = candidates)
        assertEquals(
            Recovery.Step.Switch(steady, 4_000L),
            climb(ladder, a, candidates = candidates),
        )
    }

    @Test fun `сброс начинает эпизод заново`() {
        val ladder = Recovery()
        val a = server("🇳🇱 A")
        val b = server("🇩🇪 B")
        climb(ladder, a, candidates = listOf(a to null, b to null))
        climb(ladder, a, candidates = listOf(a to null, b to null))
        ladder.reset()
        assertNull(ladder.forcedProfile())
        assertEquals(Recovery.Step.Same(1_000L), climb(ladder, b, candidates = listOf(a to null, b to null)))
    }

    @Test fun `лестница помнит только начальный сервер как уже испробованный`() {
        val ladder = Recovery()
        val a = server("🇳🇱 A")
        val b = server("🇩🇪 B")
        climb(ladder, a, candidates = listOf(a to null, b to null))
        climb(ladder, a, candidates = listOf(a to null, b to null))
        assertEquals(Recovery.Step.Switch(b, 4_000L), climb(ladder, a, candidates = listOf(a to null, b to null)))
        // B теперь тоже «пробованный», и возврат к нему невозможен.
        assertEquals(
            Recovery.Step.GiveUp("нет рабочего сервера"),
            climb(ladder, b, candidates = listOf(a to null, b to null)),
        )
    }

    @Test fun `сервер, на котором всё умерло, не возвращается даже без памяти о нём`() {
        val ladder = Recovery()
        val a = server("🇳🇱 A")
        val b = server("🇩🇪 B")
        val candidates = listOf(a to null, b to null)
        // Эпизод начат «вслепую» — отказ пришёл без id сессии, и в `tried`
        // ничего не попало. Единственный способ не назвать «переходом» возврат
        // на тот же сервер — исключение текущего.
        ladder.begin(null)
        assertTrue(ladder.step(a, MaskingProfile.balanced, candidates) is Recovery.Step.Same)
        ladder.begin(null)
        assertTrue(ladder.step(a, MaskingProfile.balanced, candidates) is Recovery.Step.Escalate)
        ladder.begin(null)
        assertEquals(Recovery.Step.Switch(b, 4_000L), ladder.step(a, MaskingProfile.maximum, candidates))
    }

    @Test fun `без линка ступенька не расходуется`() {
        val ladder = Recovery()
        val a = server("🇳🇱 A")
        ladder.begin(a.id)
        assertEquals(
            Recovery.Step.Hold(5_000L),
            ladder.step(a, MaskingProfile.balanced, listOf(a to null), online = false),
        )
        // Линк появился — эпизод продолжается с той же первой ступеньки, а не
        // с третьей: за время без сети лестница ничего не «сожгла».
        ladder.begin(a.id)
        assertEquals(
            Recovery.Step.Same(1_000L),
            ladder.step(a, MaskingProfile.balanced, listOf(a to null)),
        )
    }

    @Test fun `сколько бы пауз ни было, потолок остаётся на месте`() {
        val ladder = Recovery()
        val a = server("🇳🇱 A")
        val b = server("🇩🇪 B")
        val candidates = listOf(a to null, b to null)
        // Минута без сети = двенадцать пауз (потолок по умолчанию), и они ничего
        // не сжигают: лестница после них идёт по тем же ступенькам, что и была.
        repeat(11) {
            ladder.begin(a.id)
            assertEquals(
                Recovery.Step.Hold(5_000L),
                ladder.step(a, MaskingProfile.balanced, candidates, online = false),
            )
        }
        assertEquals(Recovery.Step.Same(1_000L), climb(ladder, a, candidates = candidates))
        assertEquals(
            Recovery.Step.Escalate(MaskingProfile.maximum, 2_000L),
            climb(ladder, a, candidates = candidates),
        )
        assertEquals(
            Recovery.Step.Switch(b, 4_000L),
            climb(ladder, a, candidates = candidates),
        )
    }

    @Test fun `пауза без линка не может длиться вечно`() {
        val ladder = Recovery(maxHolds = 3)
        val a = server("🇳🇱 A")
        val candidates = listOf(a to null, server("🇩🇪 B") to null)
        repeat(3) {
            ladder.begin(a.id)
            assertEquals(
                Recovery.Step.Hold(5_000L),
                ladder.step(a, MaskingProfile.balanced, candidates, online = false),
            )
        }
        // Четвёртая пауза уже не пауза: после лимита лестница пробует по-настоящему,
        // потому что attempt и есть проверка линка, а оценка ConnectivityManager
        // может врать.
        ladder.begin(a.id)
        assertEquals(
            Recovery.Step.Same(1_000L),
            ladder.step(a, MaskingProfile.balanced, candidates, online = false),
        )
    }

    @Test fun `после успешной ступеньки счётчик пауз обнуляется`() {
        val ladder = Recovery(maxHolds = 2)
        val a = server("🇳🇱 A")
        val candidates = listOf(a to null)
        ladder.begin(a.id)
        ladder.step(a, MaskingProfile.balanced, candidates, online = false)
        ladder.begin(a.id)
        ladder.step(a, MaskingProfile.balanced, candidates, online = false)
        // Лимит исчерпан — один настоящий шаг.
        ladder.begin(a.id)
        assertTrue(ladder.step(a, MaskingProfile.balanced, candidates, online = false) is Recovery.Step.Same)
        // А следующий обрыв снова начинается с паузы, а не с ходу лезет в attempt.
        ladder.begin(a.id)
        assertEquals(
            Recovery.Step.Hold(5_000L),
            ladder.step(a, MaskingProfile.balanced, candidates, online = false),
        )
    }
}
