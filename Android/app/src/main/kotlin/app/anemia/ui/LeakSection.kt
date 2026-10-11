package app.anemia.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import app.anemia.core.LeakCheck
import app.anemia.data.LeakChecker

/**
 * Секция «Проверка утечек» — те же строки и те же приговоры, что у
 * `LeakCheckView` на iOS. Формулировки взяты дословно: экран обещает
 * пользователю определённое, и расхождение формулировки двух платформ было бы
 * расхождением в обещании, а не в оформлении.
 *
 * Про «Без VPN» здесь сказано иначе, чем на iOS, и не зря: там адрес узнаёт
 * расширение туннеля, чьи сокеты идут мимо туннеля по построению, а здесь —
 * сокет, привязанный к сети без флага VPN.
 */
@Composable
internal fun LeakSection(checker: LeakChecker, revision: Int, onCheck: () -> Unit) {
    // Снимок по номеру перерисовки: поля `checker` — обычные @Volatile, Compose
    // о них не узнает, а без этого ряда экран мог бы показать отчёт прошлого
    // круга. Один снимок, а не три: три отдельных `remember` читали бы поле в
    // три разных момента, и круг, успевший смениться между ними, дал бы
    // отчёт одного прогона с подписью другого.
    val state = remember(revision) { LeakSnapshot(checker.report, checker.step, checker.isRunning) }
    val report = state.report
    val step = state.step
    val running = state.running
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("Проверка утечек", Modifier.weight(1f), style = MaterialTheme.typography.titleSmall)
            OutlinedButton(enabled = !running, onClick = onCheck) {
                Text(if (running) "Проверяю…" else if (report == null) "Проверить" else "Проверить снова")
            }
        }
        Text(step ?: verdict(report), style = MaterialTheme.typography.bodyLarge)
        detail(report, step)?.let {
            Text(it, style = MaterialTheme.typography.bodySmall)
        }

        report?.let { body ->
            Text(
                "Сайты видят: " + (body.exit?.let { address(it) } ?: "адрес узнать не удалось"),
                style = MaterialTheme.typography.bodyMedium,
                fontFamily = FontFamily.Monospace,
            )
            if (body.serverId != null && body.exit != null) {
                CheckRow("Трафик через VPN", tunnelCaption(body), body.bypassed, body.direct != null)
                CheckRow(
                    "IPv6",
                    when {
                        body.ipv6Leak != null -> "Идёт мимо VPN: ${body.ipv6Leak?.ip}"
                        // Два случая, в которых зелёная галочка была бы
                        // обещанием, а не результатом: выход в своей же стране
                        // (там по стране ничего не прячется) и проба «до VPN»,
                        // которая не ответила, — сравнивать не с чем.
                        body.sameCountryAsHome -> "Выход в вашей стране — сравнивать не с чем"
                        body.ipv6 != null && body.direct == null ->
                            "Нечего сравнить: проба без VPN не ответила"
                        body.ipv6 != null -> "Через VPN: ${body.ipv6?.ip}"
                        else -> "Не проверено: проба не ответила — IPv6-маршрута нет или api-ipv6.ip.sb недоступен"
                    },
                    failed = body.ipv6Leak != null,
                    known = body.ipv6Leak != null ||
                        (body.ipv6 != null && body.direct != null && !body.sameCountryAsHome),
                )
                CheckRow(
                    "DNS",
                    if (body.sameCountryAsHome && body.dnsLeak.isEmpty() && !body.dns.isNullOrEmpty())
                        "Выход в вашей стране — чьи это резолверы, непонятно"
                    else dnsCaption(body),
                    body.dnsLeak.isNotEmpty(),
                    known = !body.dns.isNullOrEmpty() && body.direct != null && !body.sameCountryAsHome,
                )
            }
            body.dns?.takeIf { it.isNotEmpty() }?.let { servers ->
                Text("DNS-серверы", style = MaterialTheme.typography.labelLarge)
                servers.forEach { server ->
                    Row(Modifier.fillMaxWidth().padding(vertical = 2.dp)) {
                        Text(server.ip, Modifier.weight(1f), style = MaterialTheme.typography.bodySmall,
                            fontFamily = FontFamily.Monospace)
                        Text(server.org ?: server.country ?: "—", style = MaterialTheme.typography.bodySmall)
                    }
                }
            }
            body.direct?.let { direct ->
                if (body.serverId != null) {
                    Text("Без VPN: ${address(direct)}", style = MaterialTheme.typography.bodySmall,
                        fontFamily = FontFamily.Monospace)
                }
            }
        }
        Text(
            "ip.sb и bash.ws на время проверки видят адрес выхода и несколько тестовых запросов.",
            style = MaterialTheme.typography.bodySmall,
        )
    }
}

@Composable
private fun CheckRow(title: String, caption: String, failed: Boolean, known: Boolean) {
    Row(Modifier.fillMaxWidth()) {
        Text(title, Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
        // Прошлый ряд — тот же, что и на iOS: молчаливое «не проверено» должно
        // читаться иначе, чем «проверено, чисто».
        Text(
            if (!known) "не проверено · $caption" else caption,
            style = MaterialTheme.typography.bodySmall,
            color = when {
                failed -> MaterialTheme.colorScheme.error
                !known -> MaterialTheme.colorScheme.onSurfaceVariant
                else -> MaterialTheme.colorScheme.primary
            },
        )
    }
}

private fun tunnelCaption(report: LeakChecker.Report): String = when {
    report.direct == null -> "Не с чем сравнить"
    report.bypassed -> "Сайты видят ваш настоящий адрес"
    else -> "Адрес выхода не ваш"
}

private fun dnsCaption(report: LeakChecker.Report): String {
    val servers = report.dns ?: return "Тест не ответил"
    val leaking = report.dnsLeak.size
    if (leaking > 0) return "$leaking ${counted(leaking, "сервер", "сервера", "серверов")} в вашей стране"
    return if (servers.isEmpty()) "Запросы не дошли до теста" else "Запросы уходят через VPN"
}

private fun address(info: LeakCheck.IPInfo): String {
    val place = listOfNotNull(info.city, info.country, info.isp).filter { it.isNotBlank() }.joinToString(" · ")
    return if (place.isEmpty()) info.ip else "${info.ip} · $place"
}

private fun verdict(report: LeakChecker.Report?): String = when (report?.verdict) {
    null -> "Не проверено"
    LeakChecker.Report.Verdict.CLEAN -> "Утечек нет"
    LeakChecker.Report.Verdict.LEAKS -> "Найдены утечки"
    LeakChecker.Report.Verdict.UNKNOWN, LeakChecker.Report.Verdict.INCOMPLETE -> "Адрес скрыт"
    LeakChecker.Report.Verdict.UNPROTECTED -> "VPN выключен"
    LeakChecker.Report.Verdict.FAILED -> "Не удалось проверить"
}

private fun detail(report: LeakChecker.Report?, step: String?): String? {
    if (step != null) return step
    if (report == null) return "Нажмите «Проверить», чтобы узнать."
    return when (report.verdict) {
        LeakChecker.Report.Verdict.CLEAN ->
            "Сайты видят адрес сервера, а DNS и IPv6 не выдают ваш настоящий."
        LeakChecker.Report.Verdict.LEAKS -> leakSummary(report)
        LeakChecker.Report.Verdict.UNKNOWN ->
            "Сравнить с адресом без VPN не удалось: сеть провайдера не ответила."
        LeakChecker.Report.Verdict.INCOMPLETE ->
            "${report.missing.joinToString(" и ")} не ответили — проверить их на утечки не удалось."
        LeakChecker.Report.Verdict.UNPROTECTED ->
            "Сайты видят ваш настоящий адрес. Включите VPN и проверьте снова."
        LeakChecker.Report.Verdict.FAILED ->
            if (report.exitUnmeasurable) {
                "Anemia вынесена из собственного туннеля (так поднимает соединение " +
                    "движок), и адрес выхода её сокетом измерить нельзя: система не " +
                    "разрешает такому приложению сокет в свой VPN. Остальное — адрес " +
                    "провайдера и DNS — на этом экране видно."
            } else {
                "ip.sb не ответил — проверьте подключение к интернету."
            }
    }
}

/** Три признака одной строкой, как `leakSummary` на iOS. */
private fun leakSummary(report: LeakChecker.Report): String {
    val parts = buildList {
        if (report.bypassed) add("трафик идёт мимо VPN")
        if (report.ipv6Leak != null) add("IPv6 выдаёт ваш адрес")
        if (report.dnsLeak.isNotEmpty()) add("DNS-запросы видит провайдер")
    }
    val text = parts.joinToString(", ")
    return text.replaceFirstChar { it.uppercase() } + "."
}

/** Отчёт, фаза и признак «идёт» — прочитанные одним глотком. */
private class LeakSnapshot(
    val report: LeakChecker.Report?,
    val step: String?,
    val running: Boolean,
)
