package app.anemia.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.anemia.core.Country
import app.anemia.core.Formatting
import app.anemia.core.MaskingProfile
import app.anemia.core.ProxyServer
import app.anemia.R

// Ground, card, ink and clay follow Sources/LoaderApp/Views/Theme.swift.
private val light = lightColorScheme(
    background = Color(0xFFFAF9F5), onBackground = Color(0xFF141413),
    surface = Color(0xFFFAF9F5), onSurface = Color(0xFF141413),
    surfaceVariant = Color(0xFFF0EEE6), onSurfaceVariant = Color(0xFF6B6A64),
    surfaceContainer = Color(0xFFF0EEE6), surfaceContainerHighest = Color(0xFFE8E6DC),
    primary = Color(0xFFC6613F), onPrimary = Color.White,
    primaryContainer = Color(0xFFF4DFD4), onPrimaryContainer = Color(0xFF642715),
    outline = Color(0xFF77736A), outlineVariant = Color(0xFFDCD9D1),
)
private val dark = darkColorScheme(
    background = Color(0xFF262624), onBackground = Color(0xFFFAF9F5),
    surface = Color(0xFF262624), onSurface = Color(0xFFFAF9F5),
    surfaceVariant = Color(0xFF30302E), onSurfaceVariant = Color(0xFFA6A39B),
    surfaceContainer = Color(0xFF30302E), surfaceContainerHighest = Color(0xFF3A3936),
    primary = Color(0xFFD97757), onPrimary = Color(0xFF3A170C),
    primaryContainer = Color(0xFF5B3527), onPrimaryContainer = Color(0xFFFFDCCF),
    outline = Color(0xFF9D998F), outlineVariant = Color(0xFF4A4944),
)

// Match the dashboard controls in the Windows client while keeping Android touch targets.
private class DashboardPalette(
    val pill: Brush,
    val rim: Brush,
    val activeTile: Brush,
    val switchTrack: Color,
    val switchEdge: Color,
    val switchThumb: Color,
    val switchActive: Color,
)

private val lightDashboard = DashboardPalette(
    pill = Brush.verticalGradient(listOf(Color(0xFFFFFEFA), Color(0xFFF5F2EB))),
    rim = Brush.verticalGradient(listOf(Color(0xFFD8D4CA), Color(0xFFE5E1D7))),
    activeTile = Brush.verticalGradient(listOf(Color(0xFFDE896E), Color(0xFFBB6043))),
    switchTrack = Color(0xFFE1DED5), switchEdge = Color(0xFFB7B3AA),
    switchThumb = Color(0xFFFCFBF8), switchActive = Color(0xFFA8442A),
)
private val darkDashboard = DashboardPalette(
    pill = Brush.verticalGradient(listOf(Color(0xFF3A3A38), Color(0xFF323231))),
    rim = Brush.verticalGradient(listOf(Color(0xFF595956), Color(0xFF393938))),
    activeTile = Brush.verticalGradient(listOf(Color(0xFFEC967C), Color(0xFFD97757))),
    switchTrack = Color(0xFF414140), switchEdge = Color(0xFF5B5B59),
    switchThumb = Color(0xFFD0D0CD), switchActive = Color(0xFFB84F2F),
)

@Composable
internal fun AnemiaTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = if (isSystemInDarkTheme()) dark else light, content = content)
}

@Composable
internal fun ConnectionHome(
    title: String,
    detail: String?,
    confirmed: Boolean,
    connecting: Boolean,
    unhealthy: Boolean,
    tunnelUp: Boolean,
    on: Boolean,
    canConnect: Boolean,
    server: ProxyServer?,
    countries: List<String>,
    serverCount: Int,
    ping: Int?,
    homeCountry: String?,
    leakClean: Boolean,
    canConnectFastest: Boolean,
    canMeasure: Boolean,
    totals: Pair<Long, Long>?,
    traffic: List<Pair<Long, Long>>,
    masking: MaskingProfile,
    adBlock: Boolean,
    lockdown: Boolean?,
    onToggle: (Boolean) -> Unit,
    onServers: () -> Unit,
    onFastest: () -> Unit,
    onMeasure: () -> Unit,
    onSettings: () -> Unit,
    onMap: () -> Unit,
    onStats: () -> Unit,
    onLeaks: () -> Unit,
    onMasking: (MaskingProfile) -> Unit,
    onAdBlock: (Boolean) -> Unit,
    onLockdown: () -> Unit,
) {
    val colors = MaterialTheme.colorScheme
    val palette = if (isSystemInDarkTheme()) darkDashboard else lightDashboard
    Box(Modifier.fillMaxWidth()) {
        ConnectionMap(server?.let { Country.code(it.name) }, confirmed,
            Modifier.fillMaxWidth().height(207.dp).padding(bottom = 16.dp)
                .clickable(onClickLabel = "Карта серверов", onClick = onMap),
            label = server?.name?.let { if (confirmed && ping != null) "$it · $ping мс" else it },
            countries = countries, homeCountry = homeCountry)
        Row(Modifier.align(Alignment.TopStart).fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Icon(painterResource(R.drawable.ic_stat_anemia), contentDescription = null,
                modifier = Modifier.size(17.dp), tint = colors.primary)
            Text("Anemia", Modifier.weight(1f).padding(start = 6.dp), fontFamily = FontFamily.Serif,
                fontWeight = FontWeight.SemiBold, fontSize = 19.sp)
            Box(Modifier.size(48.dp).clickable(role = Role.Button, onClick = onLeaks)
                .semantics { contentDescription = "Проверка утечек" }, contentAlignment = Alignment.Center) {
                Icon(painterResource(R.drawable.ic_dashboard_guard), contentDescription = null,
                    modifier = Modifier.size(14.dp), tint = colors.onSurfaceVariant)
            }
            DashboardSwitch("VPN", on, onToggle, palette, enabled = on || canConnect)
            Box(Modifier.size(48.dp).clickable(onClickLabel = "Настройки", onClick = onSettings)
                .semantics { contentDescription = "Настройки" }, contentAlignment = Alignment.Center) {
                OutlineIcon("settings", colors.onSurfaceVariant)
            }
        }
        Column(Modifier.fillMaxWidth().align(Alignment.BottomStart), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                val statusInk = if (confirmed) colors.primary else colors.onSurface
                when {
                    connecting -> CircularProgressIndicator(Modifier.size(18.dp), color = colors.primary, strokeWidth = 2.dp)
                    confirmed -> OutlineIcon("check", statusInk)
                    unhealthy -> OutlineIcon("error", colors.primary)
                    else -> OutlineIcon("shield", colors.onSurfaceVariant)
                }
                Text(title, fontFamily = FontFamily.Serif, fontWeight = FontWeight.Medium,
                    fontSize = 28.sp, lineHeight = 34.sp, color = statusInk, maxLines = 2)
            }
            detail?.let { Text(it, color = colors.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium) }
            if (serverCount > 0) {
                Row(Modifier.align(Alignment.End), horizontalArrangement = Arrangement.spacedBy(4.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.size(6.dp).border(1.dp, colors.primary, CircleShape))
                    Text(
                        counted(countries.size, "страна", "страны", "стран") + " · " +
                            counted(serverCount, "сервер", "сервера", "серверов"),
                        style = MaterialTheme.typography.labelSmall, color = colors.onSurfaceVariant,
                    )
                }
            }
        }
    }
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(4.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Surface(onClick = onServers, modifier = Modifier.weight(1f),
            shape = RoundedCornerShape(24.dp), color = Color.Transparent, border = BorderStroke(1.dp, palette.rim)) {
            Row(Modifier.background(palette.pill).padding(horizontal = 13.dp, vertical = 7.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(server?.name ?: "Выбрать сервер", style = MaterialTheme.typography.titleSmall,
                        maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(server?.let { "${it.proto.name.uppercase()} · ${it.address}" } ?: "Добавьте ссылку или подписку",
                        color = colors.onSurfaceVariant, style = MaterialTheme.typography.bodySmall,
                        maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                ping?.let { Text("$it мс", style = MaterialTheme.typography.labelMedium) }
                OutlineIcon("picker", colors.onSurfaceVariant, Modifier.size(11.dp))
            }
        }
        RoundAction("Лучший сервер", "bolt", canConnectFastest, palette, onFastest)
        RoundAction("Замерить задержку", "gauge", canMeasure, palette, onMeasure)
    }
    val rate = traffic.lastOrNull()
    Row(Modifier.fillMaxWidth().alpha(if (tunnelUp) 1f else 0.55f)
        .clickable(onClickLabel = "Статистика", onClick = onStats).padding(vertical = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
        TrafficMetric("↓", rate?.first ?: 0, totals?.first ?: 0, colors.primary)
        TrafficMetric("↑", rate?.second ?: 0, totals?.second ?: 0, colors.onSurfaceVariant)
        TrafficChart(traffic, Modifier.weight(1f).height(32.dp))
    }
    Surface(modifier = Modifier.fillMaxWidth(), shape = RoundedCornerShape(12.dp), color = colors.surfaceContainer) {
        Column(Modifier.padding(vertical = 2.dp)) {
            ProtectionRow("guard", "Kill switch", "Блокировка подключений вне VPN",
                activeTile = palette.activeTile.takeIf { lockdown == true }) {
                TextButton(onClick = onLockdown) { Text(if (lockdown == true) "Включён" else "Настроить") }
            }
            ProtectionDivider()
            ProtectionRow("masks", "Маскирование", "Профиль подключения Xray",
                activeTile = palette.activeTile.takeIf { masking != MaskingProfile.off }) {
                var expanded by remember { mutableStateOf(false) }
                Box {
                    Surface(onClick = { expanded = true }, shape = RoundedCornerShape(14.dp),
                        color = colors.surfaceContainerHighest) {
                        Row(Modifier.padding(horizontal = 10.dp, vertical = 7.dp),
                            horizontalArrangement = Arrangement.spacedBy(5.dp),
                            verticalAlignment = Alignment.CenterVertically) {
                            Text(maskingLabel(masking), style = MaterialTheme.typography.labelMedium, maxLines = 1)
                            OutlineIcon("chevron", colors.onSurfaceVariant, Modifier.size(11.dp))
                        }
                    }
                    DropdownMenu(expanded, { expanded = false }) {
                        MaskingProfile.entries.forEach { profile ->
                            DropdownMenuItem(text = { Text(maskingLabel(profile)) }, onClick = {
                                onMasking(profile)
                                expanded = false
                            })
                        }
                    }
                }
            }
            ProtectionDivider()
            ProtectionRow("block", "Без рекламы", "AdGuard DNS",
                activeTile = palette.activeTile.takeIf { adBlock }) {
                DashboardSwitch("Без рекламы", adBlock, onAdBlock, palette)
            }
            ProtectionDivider()
            ProtectionRow("eye", "Проверка утечек",
                if (leakClean) "Утечки не обнаружены" else "IPv4, IPv6 и DNS",
                activeTile = palette.activeTile.takeIf { leakClean }) {
                OutlinedButton(onClick = onLeaks, border = BorderStroke(1.dp, colors.outlineVariant),
                    contentPadding = PaddingValues(horizontal = 10.dp)) {
                    Text("Проверить", color = colors.onSurface)
                }
            }
            ProtectionDivider()
            ProtectionRow("route", "Маршрутизация", "Куда идёт трафик",
                activeTile = palette.activeTile.takeIf { confirmed }) {
                val ink = if (confirmed) colors.primary else colors.onSurfaceVariant
                Row(horizontalArrangement = Arrangement.spacedBy(5.dp), verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.size(6.dp).background(ink, CircleShape))
                    Text(if (tunnelUp) "Системный VPN" else "Отключён", color = ink)
                }
            }
        }
    }
}

private fun maskingLabel(profile: MaskingProfile): String = when (profile) {
    MaskingProfile.off -> "Выключено"
    MaskingProfile.balanced -> "Баланс"
    MaskingProfile.maximum -> "Максимум"
    else -> profile.title
}

@Composable
private fun DashboardSwitch(
    label: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    palette: DashboardPalette,
    enabled: Boolean = true,
) {
    val track = if (checked) palette.switchActive else palette.switchTrack
    val edge = if (checked) MaterialTheme.colorScheme.primary else palette.switchEdge
    Box(Modifier.size(48.dp).clip(CircleShape)
        .toggleable(value = checked, enabled = enabled, role = Role.Switch, onValueChange = onCheckedChange)
        .semantics { contentDescription = label }, contentAlignment = Alignment.Center) {
        Box(Modifier.size(width = 40.dp, height = 22.dp)
            .background(track, CircleShape).border(1.dp, edge, CircleShape).padding(horizontal = 2.dp),
            contentAlignment = if (checked) Alignment.CenterEnd else Alignment.CenterStart) {
            Box(Modifier.size(19.dp).background(
                palette.switchThumb.copy(alpha = if (enabled) 1f else 0.8f), CircleShape))
        }
    }
}

@Composable
private fun RoundAction(label: String, icon: String, enabled: Boolean, palette: DashboardPalette, onClick: () -> Unit) {
    val colors = MaterialTheme.colorScheme
    Surface(onClick = onClick, enabled = enabled,
        modifier = Modifier.size(48.dp).semantics { contentDescription = label },
        shape = CircleShape, color = Color.Transparent) {
        Box(Modifier.size(48.dp), contentAlignment = Alignment.Center) {
            Box(Modifier.size(38.dp).background(palette.pill, CircleShape).border(1.dp, palette.rim, CircleShape),
                contentAlignment = Alignment.Center) {
                OutlineIcon(icon, colors.onSurface.copy(alpha = if (enabled) 1f else 0.38f))
            }
        }
    }
}

@Composable
private fun TrafficMetric(arrow: String, rate: Long, total: Long, color: Color) {
    Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
        Surface(shape = CircleShape, color = color.copy(alpha = 0.16f)) {
            Box(Modifier.size(20.dp), contentAlignment = Alignment.Center) { Text(arrow, color = color) }
        }
        Column {
            Text(Formatting.bytes(rate) + "/с", style = MaterialTheme.typography.labelLarge)
            Text(Formatting.bytes(total), style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun TrafficChart(samples: List<Pair<Long, Long>>, modifier: Modifier) {
    val colors = MaterialTheme.colorScheme
    Canvas(modifier) {
        drawLine(colors.outlineVariant, Offset(0f, size.height - 1), Offset(size.width, size.height - 1))
        if (samples.size < 2) return@Canvas
        val max = samples.maxOf { maxOf(it.first, it.second) }.coerceAtLeast(1).toFloat()
        for (download in listOf(true, false)) {
            val line = Path()
            for ((index, sample) in samples.withIndex()) {
                val x = index * size.width / (samples.size - 1)
                val value = if (download) sample.first else sample.second
                val y = size.height - 1 - value / max * (size.height - 3)
                if (index == 0) line.moveTo(x, y) else line.lineTo(x, y)
            }
            drawPath(line, if (download) colors.primary else colors.onSurfaceVariant, style = Stroke(1.4.dp.toPx()))
        }
    }
}

@Composable
private fun ProtectionDivider() = HorizontalDivider(
    modifier = Modifier.padding(start = 50.dp), color = MaterialTheme.colorScheme.outlineVariant,
)

@Composable
private fun ProtectionRow(
    icon: String,
    title: String,
    caption: String,
    activeTile: Brush? = null,
    accessory: @Composable () -> Unit,
) {
    val colors = MaterialTheme.colorScheme
    Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 5.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
        val tile = activeTile ?: SolidColor(colors.onSurface.copy(alpha = 0.08f))
        val ink = if (activeTile != null) Color(0xFFFEF9F7) else colors.onSurfaceVariant
        Box(Modifier.size(26.dp).background(tile, RoundedCornerShape(7.dp)), contentAlignment = Alignment.Center) {
            when (icon) {
                "guard" -> Icon(painterResource(R.drawable.ic_dashboard_guard), null, Modifier.size(12.dp, 14.dp), ink)
                "masks" -> Icon(painterResource(R.drawable.ic_dashboard_masks), null, Modifier.size(20.dp, 16.dp), ink)
                else -> OutlineIcon(icon, ink, Modifier.size(14.dp))
            }
        }
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.bodyMedium)
            Text(caption, style = MaterialTheme.typography.bodySmall, color = colors.onSurfaceVariant)
        }
        accessory()
    }
}

@Composable
private fun OutlineIcon(name: String, color: Color, modifier: Modifier = Modifier.size(18.dp)) {
    Canvas(modifier) {
        val unit = size.width / 18
        val stroke = 1.45.dp.toPx()
        fun path(vararg points: Pair<Int, Int>, closed: Boolean = false, fill: Boolean = false) {
            val line = Path()
            line.moveTo(points[0].first * unit, points[0].second * unit)
            for ((x, y) in points.drop(1)) line.lineTo(x * unit, y * unit)
            if (closed) line.close()
            if (fill) drawPath(line, color) else drawPath(line, color, style = Stroke(stroke))
        }
        when (name) {
            "bolt" -> path(10 to 1, 3 to 10, 8 to 10, 7 to 17, 15 to 7, 10 to 7, closed = true, fill = true)
            "gauge" -> {
                drawCircle(color, 6.5f * unit, style = Stroke(stroke))
                path(9 to 12, 11 to 7)
            }
            "chevron" -> path(4 to 7, 9 to 12, 14 to 7)
            "picker" -> {
                path(4 to 7, 9 to 3, 14 to 7)
                path(4 to 11, 9 to 15, 14 to 11)
            }
            "block" -> {
                drawCircle(color, 7 * unit, style = Stroke(stroke))
                path(4 to 4, 14 to 14)
            }
            "eye" -> {
                drawCircle(color, 3 * unit, style = Stroke(stroke))
                path(1 to 9, 5 to 5, 13 to 5, 17 to 9, 13 to 13, 5 to 13, closed = true)
                path(2 to 2, 16 to 16)
            }
            "settings" -> {
                drawCircle(color, 6.1f * unit, style = Stroke(stroke))
                drawCircle(color, 2.3f * unit, style = Stroke(stroke))
                for (index in 0..7) {
                    val angle = index * Math.PI / 4
                    val x = kotlin.math.cos(angle).toFloat() * unit
                    val y = kotlin.math.sin(angle).toFloat() * unit
                    drawLine(color, center + Offset(x * 6.5f, y * 6.5f), center + Offset(x * 8, y * 8), stroke)
                }
            }
            "route" -> {
                path(9 to 16, 9 to 10, 3 to 4, 7 to 4)
                path(9 to 10, 15 to 4, 11 to 4)
            }
            else -> {
                path(9 to 1, 16 to 4, 16 to 11, 13 to 15, 9 to 17, 5 to 15, 2 to 11, 2 to 4, closed = true)
                when (name) {
                    "check" -> path(5 to 9, 8 to 12, 13 to 6)
                    "error" -> {
                        path(9 to 5, 9 to 10)
                        drawCircle(color, unit, Offset(9 * unit, 13 * unit))
                    }
                    else -> path(6 to 6, 12 to 12)
                }
            }
        }
    }
}
