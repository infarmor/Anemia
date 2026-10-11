package app.anemia.core

import java.util.Locale

/**
 * Where a server exits, read from its name. Port of `Country` in
 * `iOS/Activity/ActivityText.swift`: panels name servers in many ways —
 * "🇫🇷 Париж", "DE-01", "[NL] Amsterdam", "Нидерланды 2" — so the clues are
 * tried from the most to the least certain.
 *
 * The country *names* come from the system's CLDR data, which is the same
 * source on both platforms but not the same vintage: `Scripts/golden-country.sh`
 * compares this file against the Swift code and lists whatever the two
 * databases disagree on, so a difference is visible instead of silent.
 */
object Country {
    private val russian = Locale("ru")

    /** Codes panels actually use. "IN…" or "IT …" must not read as a country. */
    private val panelCodes = setOf(
        "AE", "AM", "AR", "AT", "AU", "AZ", "BE", "BG", "BR", "BY", "CA", "CH", "CL", "CY", "CZ",
        "DE", "DK", "EE", "ES", "FI", "FR", "GB", "GE", "GR", "HK", "HR", "HU", "ID", "IE", "IL",
        "IS", "JP", "KG", "KR", "KZ", "LT", "LU", "LV", "MD", "MX", "MY", "NL", "NO", "NZ", "PL",
        "PT", "RO", "RS", "RU", "SE", "SG", "SI", "SK", "TH", "TR", "TW", "UA", "US", "UZ", "VN", "ZA",
    )

    /** Where VPN servers usually stand, in the spellings panels use. */
    private val cities: List<Pair<String, String>> = listOf(
        "амстердам" to "NL", "amsterdam" to "NL", "роттердам" to "NL", "rotterdam" to "NL",
        "франкфурт" to "DE", "frankfurt" to "DE", "берлин" to "DE", "berlin" to "DE",
        "мюнхен" to "DE", "munich" to "DE", "нюрнберг" to "DE", "nuremberg" to "DE",
        "фалькенштайн" to "DE", "falkenstein" to "DE", "дюссельдорф" to "DE", "dusseldorf" to "DE",
        "париж" to "FR", "paris" to "FR", "марсель" to "FR", "marseille" to "FR",
        "лондон" to "GB", "london" to "GB", "манчестер" to "GB", "manchester" to "GB",
        "хельсинки" to "FI", "helsinki" to "FI", "стокгольм" to "SE", "stockholm" to "SE",
        "осло" to "NO", "oslo" to "NO", "копенгаген" to "DK", "copenhagen" to "DK",
        "варшава" to "PL", "warsaw" to "PL", "рига" to "LV", "riga" to "LV",
        "таллин" to "EE", "таллинн" to "EE", "tallinn" to "EE", "вильнюс" to "LT", "vilnius" to "LT",
        "прага" to "CZ", "prague" to "CZ", "вена" to "AT", "vienna" to "AT",
        "цюрих" to "CH", "zurich" to "CH", "женева" to "CH", "geneva" to "CH",
        "милан" to "IT", "milan" to "IT", "мадрид" to "ES", "madrid" to "ES",
        "барселона" to "ES", "barcelona" to "ES", "лиссабон" to "PT", "lisbon" to "PT",
        "дублин" to "IE", "dublin" to "IE", "брюссель" to "BE", "brussels" to "BE",
        "люксембург" to "LU", "будапешт" to "HU", "budapest" to "HU", "бухарест" to "RO",
        "bucharest" to "RO", "софия" to "BG", "sofia" to "BG", "белград" to "RS", "belgrade" to "RS",
        "афины" to "GR", "athens" to "GR", "стамбул" to "TR", "istanbul" to "TR",
        "тбилиси" to "GE", "tbilisi" to "GE", "ереван" to "AM", "yerevan" to "AM",
        "баку" to "AZ", "baku" to "AZ", "алматы" to "KZ", "almaty" to "KZ", "астана" to "KZ",
        "astana" to "KZ", "ташкент" to "UZ", "tashkent" to "UZ", "бишкек" to "KG", "bishkek" to "KG",
        "кишинёв" to "MD", "кишинев" to "MD", "chisinau" to "MD", "москва" to "RU", "moscow" to "RU",
        "санкт петербург" to "RU", "петербург" to "RU", "saint petersburg" to "RU",
        "токио" to "JP", "tokyo" to "JP", "осака" to "JP", "osaka" to "JP", "сеул" to "KR", "seoul" to "KR",
        "сингапур" to "SG", "гонконг" to "HK", "hong kong" to "HK", "тайбэй" to "TW", "taipei" to "TW",
        "дубай" to "AE", "dubai" to "AE", "тель авив" to "IL", "tel aviv" to "IL",
        "нью йорк" to "US", "new york" to "US", "лос анджелес" to "US", "los angeles" to "US",
        "майами" to "US", "miami" to "US", "чикаго" to "US", "chicago" to "US", "даллас" to "US",
        "dallas" to "US", "сиэтл" to "US", "seattle" to "US", "сан франциско" to "US",
        "san francisco" to "US", "сан хосе" to "US", "san jose" to "US", "ашберн" to "US", "ashburn" to "US",
        "торонто" to "CA", "toronto" to "CA", "монреаль" to "CA", "montreal" to "CA",
        "ванкувер" to "CA", "vancouver" to "CA", "сидней" to "AU", "sydney" to "AU",
        "мельбурн" to "AU", "melbourne" to "AU", "сан паулу" to "BR", "sao paulo" to "BR",
        "йоханнесбург" to "ZA", "johannesburg" to "ZA",
    )

    /** ISO region code of the exit, or null when the name doesn't reveal one. */
    fun code(serverName: String): String? =
        flagCode(serverName) ?: leadingCode(serverName) ?: namedCode(serverName)

    /** "FR" → 🇫🇷. Как Swift: каждый ASCII-буквенный скаляр становится
     * региональным индикатором, остальные просто выпадают — «RUS» даёт три
     * флага, «A1» один, а не пустую строку. */
    fun flag(code: String): String {
        val builder = StringBuilder()
        code.uppercase().forEach { letter ->
            if (letter in 'A'..'Z') builder.appendCodePoint(0x1F1E6 - 'A'.code + letter.code)
        }
        return builder.toString()
    }

    /** "FR" → "Франция" in the system's Russian CLDR.
     *
     * `Locale(String, String)`, not `Locale.Builder`: it is the shape that
     * matches Swift's `localizedString(forRegionCode:) ?? code`, because it
     * never rejects a region and hands back the code when nothing resolves.
     * The Builder throws on «1» and «RUS», and this argument can be the raw
     * `loc=` field of a leak service's answer.
     *
     * The "nothing resolved" test is the locale's own region, not the argument:
     * the JVM uppercases it on the way in, so «XxX» and «el» would come back as
     * «XXX» and «EL» where Swift returns the string it was given.
     */
    fun name(code: String): String {
        val locale = Locale("", code)
        val localized = locale.getDisplayCountry(russian)
        return if (localized == locale.country) code else localized
    }

    /**
     * The server's name without flags ("🇳🇱 Амстердам #2" → "Амстердам #2").
     * Walked by code points: a flag is a surrogate pair, and filtering by
     * `Char` would see two halves of it and keep both.
     */
    fun place(serverName: String): String {
        val builder = StringBuilder()
        var index = 0
        while (index < serverName.length) {
            val point = serverName.codePointAt(index)
            if (point !in 0x1F1E6..0x1F1FF) builder.appendCodePoint(point)
            index += Character.charCount(point)
        }
        return builder.toString().trim { isSpaceLike(it) || isPunctuation(it) }
    }

    /** `Character.isNumber` у Foundation — это Nd + Nl + No; Kotlin's
     * `isLetterOrDigit` знает только Nd, и «³» для него не цифра. */
    internal fun Char.isNumberLike(): Boolean =
        Character.getType(this) in numberTypes

    private val numberTypes = setOf(
        Character.DECIMAL_DIGIT_NUMBER.toInt(), Character.LETTER_NUMBER.toInt(),
        Character.OTHER_NUMBER.toInt(),
    )

    /** Unicode general category P*, what Foundation calls `.punctuationCharacters`. */
    private fun isPunctuation(ch: Char): Boolean =
        punctuationTypes.contains(Character.getType(ch).toInt())

    private val punctuationTypes: Set<Int> = setOf(
        Character.DASH_PUNCTUATION, Character.START_PUNCTUATION, Character.END_PUNCTUATION,
        Character.CONNECTOR_PUNCTUATION, Character.OTHER_PUNCTUATION,
        Character.INITIAL_QUOTE_PUNCTUATION, Character.FINAL_QUOTE_PUNCTUATION,
    ).map { it.toInt() }.toSet()

    // MARK: - Clues

    /** A flag emoji: two regional-indicator letters, by code point. */
    private fun flagCode(name: String): String? {
        val flags = mutableListOf<Int>()
        var index = 0
        while (index < name.length && flags.size < 2) {
            val point = name.codePointAt(index)
            if (point in 0x1F1E6..0x1F1FF) flags.add(point)
            index += Character.charCount(point)
        }
        if (flags.size < 2) return null
        return flags.joinToString("") { String(Character.toChars(it - 0x1F1E6 + 'A'.code)) }
    }

    /**
     * A capitalized code standing alone at the start: "DE-01", "[NL] …",
     * "US | 3". Only codes panels actually use, so a name that merely starts
     * with two capitals isn't taken for a country.
     */
    private fun leadingCode(serverName: String): String? {
        val trimmed = serverName.dropWhile { it in " [(【{" }
        // Swift берёт два первых `Character`'а — это графемные кластеры, а не
        // кодовые точки: «DE◌́-01» (E с объединяющим ударением) для него один
        // кластер «É», не буква A…Z, и страна не находится. По UTF-16-символам
        // та же строка читалась бы как «DE».
        val clusters = graphemes(trimmed)
        val letters = clusters.take(2)
        if (letters.size != 2 || !letters.all { it.length == 1 && it[0] in 'A'..'Z' }) return null
        val next = clusters.getOrNull(2)?.firstOrNull()
        if (next != null && next.isLetter()) return null
        val code = if (letters.joinToString("") == "UK") "GB" else letters.joinToString("")
        return code.takeIf { it in panelCodes }
    }

    /** Разбиение на графемные кластеры — то, чем в Swift является `Character`. */
    private fun graphemes(text: String): List<String> {
        val iterator = java.text.BreakIterator.getCharacterInstance()
        iterator.setText(text)
        val out = ArrayList<String>()
        var start = iterator.first()
        while (true) {
            val next = iterator.next()
            if (next == java.text.BreakIterator.DONE) break
            out.add(text.substring(start, next))
            start = next
        }
        return out
    }

    /** A city or a country named in words, matched as whole words. */
    private fun namedCode(serverName: String): String? {
        val text = " " + words(serverName) + " "
        cities.firstOrNull { (city, _) -> text.contains(" $city ") }?.let { return it.second }
        for (region in Locale.getISOCountries()) {
            if (region.length != 2 || !region.all { it.isLetter() }) continue
            for (locale in listOf(russian, Locale("en", "US"))) {
                // The name of `region` as that locale says it — not the
                // locale's own country, which is what `displayCountry` on the
                // locale itself returns.
                val localized = Locale.Builder().setRegion(region).build().getDisplayCountry(locale)
                val country = words(localized)
                if (country.length >= 4 && text.contains(" $country ")) return region
            }
        }
        return null
    }

    /** Lowercased letters and digits, everything else a single space. */
    private fun words(text: String): String =
        text.lowercase()
            .map { if (it.isLetter() || it.isNumberLike()) it else ' ' }
            .joinToString("")
            .split(' ')
            .filter { it.isNotEmpty() }
            .joinToString(" ")
}
