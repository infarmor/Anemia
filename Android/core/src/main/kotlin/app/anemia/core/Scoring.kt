package app.anemia.core

import kotlin.math.roundToInt

/**
 * Port of `Sources/LoaderCore/ServerScoring.swift` and `KxcFeatures.swift`: the
 * hand-built view of a probe history (RTT in ms; a failed probe is −1) and the
 * fixed feature vector the kxc ranker reads.
 *
 * These are floats computed a second time, on a second platform, so the golden
 * compares IEEE-754 bits rather than printed decimals — and where the two
 * `pow` implementations disagree in the last bit the check says so out loud
 * instead of quietly widening its tolerance.
 */
object ServerScoring {

    /** Best/average latency, jitter, tail, loss and drift; 100 000 when nothing worked. */
    fun rankingScore(history: List<Float>): Double {
        val v = history.filter { it >= 0 }.map { it.toDouble() }
        if (v.isEmpty()) return 100_000.0
        val mean = v.sum() / v.size
        val mn = v.minOrNull() ?: mean
        val mx = v.maxOrNull() ?: mean
        val std = kotlin.math.sqrt(v.sumOf { (it - mean) * (it - mean) } / v.size)
        val loss = (history.size - v.size).toDouble() / history.size
        val trend = slope(v)
        return 0.6 * mean + 0.4 * mn +
            std * (1 + mean / 200) +
            maxOf(0.0, mx - mean) * 0.3 +
            1000 * loss * (1 + loss) +
            maxOf(0.0, trend) * v.size * 0.5
    }

    /** Linear-regression slope (units per step); positive is worsening. */
    fun slope(y: List<Double>): Double {
        val n = y.size
        if (n <= 1) return 0.0
        val mx = (n - 1) / 2.0
        val my = y.sum() / n
        var num = 0.0
        var den = 0.0
        for (i in 0 until n) {
            val dx = i - mx
            num += dx * (y[i] - my)
            den += dx * dx
        }
        return if (den == 0.0) 0.0 else num / den
    }

    /** Plain average RTT — the ranking used when the ML ranker is off. */
    fun averagePing(history: List<Float>): Double {
        val ok = history.filter { it >= 0 }
        if (ok.isEmpty()) return 100_000.0
        // Summed in Float, as Swift's `reduce(0, +)` over `[Float]` does: the
        // Double version is more accurate and would rank differently.
        return ok.fold(0f) { acc, value -> acc + value }.toDouble() / ok.size
    }

    /**
     * Dependability in 0…1, independent of speed: loss, jitter and upward
     * drift, multiplied, recency-weighted — so a server that only now started
     * dropping packets scores low instead of hiding behind a clean past.
     */
    fun stability(history: List<Float>): Double {
        val h = history
        if (h.isEmpty()) return 0.0
        val decay = 0.94
        val n = h.size
        var wTotal = 0.0
        var wLoss = 0.0
        var wValid = 0.0
        var wSum = 0.0
        // Те же веса, что у Swift: `decay` умножением, а не `pow` —
        // транцендентенты две математические библиотеки считают в последних битах
        // по-разному, а этот показатель идёт в ранкер.
        val weights = DoubleArray(n)
        var weight = 1.0
        for (i in n - 1 downTo 0) {
            weights[i] = weight
            weight *= decay
        }
        for (i in 0 until n) {
            val w = weights[i]
            wTotal += w
            if (h[i] < 0) wLoss += w else {
                wValid += w
                wSum += w * h[i]
            }
        }
        val loss = if (wTotal > 0) wLoss / wTotal else 1.0
        val spare = maxOf(0.0, 1 - loss)
        val lossTerm = spare * kotlin.math.sqrt(spare)
        if (wValid <= 0) return 0.0
        val mean = wSum / wValid
        var wVar = 0.0
        for (i in 0 until n) {
            if (h[i] >= 0) wVar += weights[i] * (h[i] - mean) * (h[i] - mean)
        }
        val std = kotlin.math.sqrt(wVar / wValid)
        val cv = if (mean > 0) std / mean else 1.0
        val valid = h.filter { it >= 0 }.map { it.toDouble() }
        val drift = if (valid.size >= 2) maxOf(0.0, slope(valid)) / maxOf(mean, 1.0) else 0.0
        val jitterTerm = 1 / (1 + 4 * cv)
        val driftTerm = 1 / (1 + 8 * drift)
        val product = lossTerm * jitterTerm * driftTerm
        // То же, что на Swift: нечисловая история не получает «идеальной»
        // стабильности (там min(1, NaN) возвращает 1, здесь maxOf дал бы NaN).
        if (!product.isFinite()) return 0.0
        return maxOf(0.0, minOf(1.0, product))
    }
}

/** kxc v4's fixed 25-feature view of a probe history — the trainer's and the app's. */
object KxcFeatures {
    const val count = 25
    const val window = 256
    const val horizon = 32
    const val scoreCap = 4000.0
    private const val deadRTT = 3000.0

    fun names(): List<String> =
        (0 until count).map { String.format(java.util.Locale.ROOT, "f%02d", it) }

    fun extract(fullHistory: List<Float>): List<Double> {
        val h = if (fullHistory.size > window) fullHistory.takeLast(window) else fullHistory
        val n = h.size
        val valid = h.filter { it >= 0 }.map { it.toDouble() }

        fun lossRate(slice: List<Float>): Double =
            if (slice.isEmpty()) 0.0 else slice.count { it < 0 }.toDouble() / slice.size

        fun mean(x: List<Double>): Double? = if (x.isEmpty()) null else x.sum() / x.size

        fun std(x: List<Double>, m: Double): Double =
            if (x.isEmpty()) 0.0 else kotlin.math.sqrt(x.sumOf { (it - m) * (it - m) } / x.size)

        fun median(x: List<Double>): Double? {
            if (x.isEmpty()) return null
            val s = x.sorted()
            return if (s.size % 2 == 1) s[s.size / 2] else (s[s.size / 2 - 1] + s[s.size / 2]) / 2
        }

        // Loss: overall, recent, recency-weighted, and its shape.
        val lossAll = lossRate(h)
        val loss16 = lossRate(h.takeLast(16))
        var ewLoss = 0.0
        var ewTotal = 0.0
        var w = 1.0
        for (i in h.indices.reversed()) {
            if (h[i] < 0) ewLoss += w
            ewTotal += w
            w *= 0.9
        }
        val lossEW = if (ewTotal > 0) ewLoss / ewTotal else 0.0
        var longestRun = 0
        var runs = 0
        var run = 0
        for (sample in h.takeLast(64)) {
            if (sample < 0) {
                run += 1
                if (run == 1) runs += 1
                if (run > longestRun) longestRun = run
            } else {
                run = 0
            }
        }
        val lastFailed = if ((h.lastOrNull() ?: 0f) < 0) 1.0 else 0.0
        // How many samples back the most recent failure is — Swift reads this off
        // the reversed view, so a failing last probe is 0, not `n - 1`.
        val sinceFail = ((0 until n).firstOrNull { h[n - 1 - it] < 0 } ?: n).toDouble()

        // Latency: level, spread, tail — overall and now.
        val sorted = valid.sorted()
        val meanAll = mean(valid) ?: deadRTT
        val medianAll = median(valid) ?: deadRTT
        val minAll = sorted.firstOrNull() ?: deadRTT
        val p90All = if (sorted.isEmpty()) deadRTT
        else sorted[((sorted.size - 1) * 0.9).roundToInt()]
            // roundToInt(), а не kotlin.math.round(): у первого «.5» идёт к
            // бесконечности, как у Swift `rounded()`, а второе отдаёт ±Infinity
            // для NaN-входа и вообще другой тип. Шестистовая история
            // «10,20,30,40,50,600» попадает ровно на 4.5 — там разница стоит
            // 550 мс в поле f09, и gold-сверка бьёт бит в бит только на этом
            // варианте.
        val stdAll = std(valid, meanAll)
        val recent16 = h.takeLast(16).filter { it >= 0 }.map { it.toDouble() }
        val mean16 = mean(recent16) ?: meanAll
        val std16 = if (recent16.isEmpty()) stdAll else std(recent16, mean16)
        val mean4 = mean(valid.takeLast(4)) ?: meanAll

        // Recency-weighted level and absolute deviation over successful probes.
        var ewMean = 0.0
        var ewWeight = 0.0
        w = 1.0
        for (i in valid.indices.reversed()) {
            ewMean += w * valid[i]
            ewWeight += w
            w *= 0.85
        }
        ewMean = if (ewWeight > 0) ewMean / ewWeight else deadRTT
        var ewDev = 0.0
        w = 1.0
        for (i in valid.indices.reversed()) {
            ewDev += w * kotlin.math.abs(valid[i] - ewMean)
            w *= 0.85
        }
        ewDev = if (ewWeight > 0) ewDev / ewWeight else 0.0

        // Drift and level shifts.
        val slopeAll = ServerScoring.slope(valid)
        val slope32 = ServerScoring.slope(h.takeLast(32).filter { it >= 0 }.map { it.toDouble() })
        val recentOverAll = mean16 / maxOf(meanAll, 1.0)
        val prior = h.dropLast(16).filter { it >= 0 }.map { it.toDouble() }
        val levelShift = (median(recent16) ?: mean16) - (median(prior) ?: medianAll)

        // The hand-built views, as features the trees can correct.
        val scoreAll = minOf(scoreCap, ServerScoring.rankingScore(h))
        val score32 = minOf(scoreCap, ServerScoring.rankingScore(h.takeLast(horizon)))
        val stability = ServerScoring.stability(h)

        return listOf(
            n.toDouble(), lossAll, loss16, lossEW, longestRun.toDouble(),
            runs.toDouble(), meanAll, medianAll, minAll, p90All,
            stdAll, mean16, std16, mean4, ewMean,
            ewDev, slopeAll, slope32, recentOverAll, scoreAll,
            score32, stability, lastFailed, minOf(sinceFail, window.toDouble()), levelShift,
        )
    }
}
