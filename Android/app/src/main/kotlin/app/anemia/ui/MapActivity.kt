package app.anemia.ui

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.layout.Column
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import app.anemia.core.Country
import app.anemia.core.MapGeo
import app.anemia.data.SessionStarter
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

/**
 * Карта мира — порт `iOS/Anemia/WorldMap.swift` в той части, которая статична:
 * соты суши, тёплые страны, где лежат серверы, метка выхода и подпись страны по
 * нажатию.
 *
 * Чего здесь нет и почему сказано вслух:
 *  - отметка «Вы» и дуга строятся по адресу провайдера из проверки утечек;
 *  - бегущие по маршруту пакеты и 30 fps-анимация — на iOS это отдельный
 *    `TimelineView`, и ровно тот же экран без него выглядит как режим
 *    «уменьшить движение»;
 *  - выбор сервера нажатием работает, только пока туннель не поднят (как на
 *    iOS: `canPick`).
 *
 * Геометрия не переписана руками: `assets/map.json` генерируется из
 * `iOS/Anemia/MapData.swift` скриптом `Scripts/golden-map.sh`, а выборка сот
 * сверяется с Swift побитно (`MapGeoTest`).
 */
class MapActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            AnemiaTheme {
                Surface(Modifier.fillMaxSize()) {
                    MapScreen(onBack = { finish() })
                }
            }
        }
    }
}

@Composable
internal fun ConnectionMap(
    country: String?, active: Boolean, modifier: Modifier = Modifier, label: String? = null,
    countries: List<String> = emptyList(),
    homeCountry: String? = null,
) {
    val map = rememberMap()
    val dark = androidx.compose.foundation.isSystemInDarkTheme()
    val land = MaterialTheme.colorScheme.onSurface.copy(alpha = if (dark) 0.20f else 0.16f)
    val accent = MaterialTheme.colorScheme.primary
    val ground = MaterialTheme.colorScheme.surface
    val ink = MaterialTheme.colorScheme.onSurface
    val paint = remember { android.text.TextPaint(android.graphics.Paint.ANTI_ALIAS_FLAG) }
    Canvas(modifier) {
        val geo = map ?: return@Canvas
        val rect = fit(size.width, size.height, geo.aspect)
        val step = rect.width / 180f
        fun plot(center: DoubleArray) = Offset(rect.left + geo.projectX(center[1]).toFloat() * rect.width,
            rect.top + geo.projectY(center[0]).toFloat() * rect.height)
        val parks = countries.mapNotNull { geo.centers[it.uppercase()] }.map(::plot)
        val range = step * 3.5f
        for (cell in geo.landCells) {
            val fade = (1f - (cell.y.toFloat() - 0.48f).coerceAtLeast(0f) * 1.8f).coerceAtLeast(0.05f)
            val point = Offset(
                rect.left + cell.x.toFloat() * rect.width,
                rect.top + cell.y.toFloat() * rect.height,
            )
            val nearest = parks.minOfOrNull { (it - point).getDistanceSquared() } ?: Float.MAX_VALUE
            val warmth = (1f - kotlin.math.sqrt(nearest) / range).coerceAtLeast(0f)
            val color = if (warmth > 0) accent.copy(alpha = (0.32f + 0.44f * warmth) * fade)
                else land.copy(alpha = land.alpha * fade)
            drawCircle(color, step * 0.36f, point)
        }
        for (park in parks) drawCircle(accent.copy(alpha = 0.60f), step * 1.48f, park, style = Stroke(0.8.dp.toPx()))
        val home = geo.centers[homeCountry?.uppercase()]?.let(::plot)
        val exit = geo.centers[country?.uppercase()]?.let(::plot)
        drawHomeRoute(home, exit, active, ground, ink, accent, paint)
        geo.centers[country?.uppercase()]?.let { center ->
            val pin = plot(center)
            if (active) drawCircle(accent.copy(alpha = 0.22f), step * 3.2f, pin)
            drawCircle(accent, step * 1.65f, pin)
            if (!label.isNullOrBlank()) {
                paint.color = (if (active) accent else ink).toArgb()
                paint.textSize = 11.sp.toPx()
                val caption = android.text.TextUtils.ellipsize(label, paint, 112.dp.toPx(),
                    android.text.TextUtils.TruncateAt.END).toString()
                val gap = 6.dp.toPx()
                val width = paint.measureText(caption) + gap * 2
                val height = paint.descent() - paint.ascent() + gap
                val start = if (pin.x > size.width / 2) pin.x - width - gap else pin.x + gap
                val left = start.coerceIn(0f, (size.width - width).coerceAtLeast(0f))
                val top = (pin.y - height / 2).coerceAtLeast(0f)
                val corner = CornerRadius(height / 2)
                drawRoundRect(ground, Offset(left, top), Size(width, height), corner)
                drawRoundRect(accent.copy(alpha = 0.65f), Offset(left, top), Size(width, height), corner,
                    style = Stroke(0.8.dp.toPx()))
                drawIntoCanvas { canvas ->
                    canvas.nativeCanvas.drawText(caption, left + gap, top + gap / 2 - paint.ascent(), paint)
                }
            }
        }
    }
}

private fun DrawScope.drawHomeRoute(
    home: Offset?, exit: Offset?, active: Boolean, ground: Color, ink: Color, accent: Color,
    paint: android.text.TextPaint,
) {
    if (home == null) return
    if (active && exit != null && exit != home) {
        val route = Path().apply {
            moveTo(home.x, home.y)
            quadraticTo((home.x + exit.x) / 2,
                min(home.y, exit.y) - min(32.dp.toPx(), kotlin.math.abs(home.x - exit.x) * 0.25f),
                exit.x, exit.y)
        }
        drawPath(route, accent, style = Stroke(1.15.dp.toPx()))
    }
    drawCircle(ground, 4.dp.toPx(), home)
    drawCircle(ink, 2.dp.toPx(), home)
    paint.color = ink.toArgb()
    paint.textSize = 10.sp.toPx()
    val label = "Вы"
    val gap = 7.dp.toPx()
    val left = if (home.x >= paint.measureText(label) + gap) home.x - paint.measureText(label) - gap else home.x + gap
    drawIntoCanvas { canvas ->
        canvas.nativeCanvas.drawText(label, left, home.y + paint.textSize / 3, paint)
    }
}

@Composable
private fun rememberMap(): MapGeo? {
    val assets = LocalContext.current.assets
    var map by remember(assets) { mutableStateOf<MapGeo?>(null) }
    LaunchedEffect(assets) {
        map = withContext(Dispatchers.Default) {
            runCatching {
                assets.open("map.json").bufferedReader().use { MapGeo.parse(it.readText()) }
                    .also { it.landCells }
            }.getOrNull()
        }
    }
    return map
}

/** Страна, где лежит хотя бы один сервер, с их числом и лучшим замером. */
private data class Park(val code: String, val count: Int, val best: Int?)

@Composable
private fun MapScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    val store = remember { sharedStore(context) }
    val probes = remember { sharedProbes(context) }
    val geo = rememberMap()
    var notice by remember { mutableStateOf<String?>(null) }
    var revision by remember { mutableStateOf(0) }

    val servers = remember(revision) { store.servers }
    val selected = remember(revision) { store.selected() }
    // Живой ли туннель — здесь спрашивают у системы, а не у `TunnelLive`: то
    // поле пишет `MainActivity`, а к карте можно прийти ярлыком в холодный
    // процесс. Тогда `up` осталось бы false навсегда, и экран разрешил бы
    // менять выход посреди живой сессии — ровно то, что запрещает комментарий
    // ниже.
    val app = context.applicationContext
    var systemUp by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        while (true) {
            // Binder-вызов и перечисление интерфейсов — вне главной нити.
            systemUp = withContext(Dispatchers.IO) { SessionStarter.tunnelUp(app) }
            delay(2_000)
        }
    }
    // Только системный источник: `TunnelLive.up` пишет `MainActivity`, а
    // «или» умело бы только включать запрет, но не снимать его — молча
    // убитый сервис оставил бы поле `true`, и выбрать выход с карты было бы
    // нельзя уже никогда. `sessionId` берётся из широковещания как и раньше.
    val live = systemUp
    // Группируются сами серверы, а не имена: два разных выхода могут называться
    // одинаково, и «первый с таким именем» дал бы чужой замер и чужой выбор.
    val parks = remember(servers) {
        servers.mapNotNull { server -> Country.code(server.name)?.uppercase()?.let { it to server } }
            .groupBy({ it.first }, { it.second })
            .map { (code, list) ->
                Park(code, list.size, list.mapNotNull { probes.pingOf(it.id) }.minOrNull())
            }.sortedBy { it.code }
    }
    val exit = (TunnelLive.sessionId ?: selected?.id)?.let { id ->
        servers.firstOrNull { it.id == id }
    } ?: selected
    val exitCode = exit?.let { Country.code(it.name)?.uppercase() }
    val homeCode = sharedLeaks(context).report?.direct?.countryCode?.uppercase()
    val homePaint = remember { android.text.TextPaint(android.graphics.Paint.ANTI_ALIAS_FLAG) }
    val ground = MaterialTheme.colorScheme.surface
    val ink = MaterialTheme.colorScheme.onSurface
    // Жест читает свежие данные: `pointerInput` живёт в корутине, созданной при
    // первой композиции с готовой картой, и без `rememberUpdatedState` второй
    // тап видел бы список серверов и выбор до первого тапа — в том числе
    // страну, добавленную раундом подписки, выбрать было бы нельзя.
    val currentParks by rememberUpdatedState(parks)
    val currentServers by rememberUpdatedState(servers)
    val currentExitCode by rememberUpdatedState(exitCode)
    val currentLive by rememberUpdatedState(live)

    Box(Modifier.fillMaxSize().safeDrawingPadding()) {
        val map = geo
        if (map == null) {
            Text(
                "карта…",
                Modifier.align(Alignment.Center),
                style = MaterialTheme.typography.bodyMedium,
            )
        } else {
            var chip by remember { mutableStateOf<String?>(null) }
            // Палитра читается здесь: внутри `Canvas { }` уже DrawScope, а не
            // композиция, и `MaterialTheme` оттуда не вызвать.
            val land = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.35f)
            val warm = MaterialTheme.colorScheme.primary
            Canvas(
                Modifier.fillMaxSize().pointerInput(map) {
                    detectTapGestures { point ->
                        val rect = fit(size.width.toFloat(), size.height.toFloat(), map.aspect)
                        val parksNow = currentParks
                        val exitNow = currentExitCode
                        val code = nearest(parksNow.map { it.code } + listOfNotNull(exitNow),
                            map, rect, point, 22f * density)
                        if (code == null) { chip = null; return@detectTapGestures }
                        val park = parksNow.firstOrNull { it.code == code }
                        chip = buildString {
                            append(Country.flag(code)); append(' '); append(Country.name(code))
                            val facts = ArrayList<String>()
                            if (code == exitNow) facts.add(if (currentLive) "выход" else "выбран выход")
                            park?.let {
                                facts.add(counted(it.count, "сервер", "сервера", "серверов"))
                                it.best?.let { best -> facts.add("лучший $best мс") }
                            }
                            if (facts.isNotEmpty()) { append("\n"); append(facts.joinToString(" · ")) }
                        }
                        // Как на iOS: пока туннель жив, нажатие только называет
                        // страну — переключать выход посреди сессии нельзя.
                        if (park != null && code != exitNow && !currentLive) {
                            val best = currentServers
                                .filter { Country.code(it.name)?.uppercase() == code }
                                .minByOrNull { probes.pingOf(it.id) ?: Int.MAX_VALUE }
                            if (best != null) {
                                store.select(best.id)
                                revision++
                                notice = "выбран ${best.name}"
                            }
                        }
                    }
                }
            ) {
                val rect = fit(size.width, size.height, map.aspect)
                if (rect.width < 1f) return@Canvas
                val step = rect.width / 180f
                val radius = step * 0.37f
                val centers = parks.mapNotNull { map.centers[it.code] }
                for (cell in map.landCells) {
                    val x = rect.left + cell.x.toFloat() * rect.width
                    val y = rect.top + cell.y.toFloat() * rect.height
                    var warmth = 0.0
                    for (center in centers) {
                        val dLat = cell.lat - center[0]
                        val dLon = (cell.lon - center[1]) * cos(cell.lat * PI / 180.0)
                        warmth = max(warmth, 1.0 - max(0.0, hypot(dLat, dLon)) / WARM_RADIUS)
                    }
                    val color = if (warmth <= 0) land
                    else warm.copy(alpha = 0.30f + 0.15f * min(3, (warmth * 3).roundToInt()))
                    drawCircle(color, radius, Offset(x, y))
                }
                fun point(code: String?) = map.centers[code]?.let { center ->
                    Offset(rect.left + map.projectX(center[1]).toFloat() * rect.width,
                        rect.top + map.projectY(center[0]).toFloat() * rect.height)
                }
                val pin = point(exitCode)
                drawHomeRoute(point(homeCode), pin, live, ground, ink, warm, homePaint)
                if (pin != null) {
                    drawCircle(warm, radius = step * 1.6f, center = pin)
                    drawCircle(warm.copy(alpha = 0.4f), radius = step * 3f, center = pin)
                }
            }
            Column(Modifier.align(Alignment.TopCenter).padding(top = 8.dp),
                horizontalAlignment = Alignment.CenterHorizontally) {
                chip?.let {
                    Text(it, style = MaterialTheme.typography.bodyMedium, textAlign = TextAlign.Center)
                }
            }
            if (parks.isNotEmpty()) {
                Text(
                    "${counted(parks.size, "страна", "страны", "стран")} · " +
                        counted(parks.sumOf { it.count }, "сервер", "сервера", "серверов"),
                    Modifier.align(Alignment.TopEnd).padding(top = 6.dp, end = 16.dp),
                    style = MaterialTheme.typography.labelMedium,
                )
            }
        }
        TextButton(
            onClick = onBack,
            modifier = Modifier.align(Alignment.TopStart),
        ) { Text("← Назад") }
        notice?.let {
            Text(
                it,
                Modifier.fillMaxWidth().align(Alignment.BottomStart).padding(16.dp),
                style = MaterialTheme.typography.bodySmall,
            )
        }
    }
}

/** Прямоугольник карты с вписанным соотношением сторон — порт `MapGeometry.fit`. */
private fun fit(width: Float, height: Float, aspect: Double): androidx.compose.ui.geometry.Rect {
    if (width <= 0f || height <= 0f) return androidx.compose.ui.geometry.Rect.Zero
    val w = min(width, (height * aspect.toFloat()))
    val h = w / aspect.toFloat()
    return androidx.compose.ui.geometry.Rect(
        Offset((width - w) / 2f, (height - h) / 2f),
        Offset((width - w) / 2f + w, (height - h) / 2f + h),
    )
}

/** Ближайшая размещаемая страна в пределах подушки пальца — `nearestCountry`. */
private fun nearest(
    codes: List<String?>,
    map: MapGeo,
    rect: androidx.compose.ui.geometry.Rect,
    point: Offset,
    radius: Float,
): String? {
    var best: Pair<String, Float>? = null
    for (code in codes.filterNotNull().distinct()) {
        val center = map.centers[code] ?: continue
        val x = rect.left + map.projectX(center[1]).toFloat() * rect.width
        val y = rect.top + map.projectY(center[0]).toFloat() * rect.height
        val distance = hypot(x - point.x, y - point.y)
        if (distance < radius && distance < (best?.second ?: Float.MAX_VALUE)) best = code to distance
    }
    return best?.first
}

/** Радиус «тепла» в градусах — тот же, что на iOS. */
private const val WARM_RADIUS = 7.0
