import Foundation

/// Network speed the way the app and the Live Activity show it.
enum Speed {
    private static let units = ["Кбит/с", "Мбит/с", "Гбит/с"]
    private static let compactUnits = ["К", "М", "Г"]
    private static let locale = Locale(identifier: "ru_RU")

    /// ("48,2", "Мбит/с")
    static func parts(_ bitsPerSecond: Double) -> (value: String, unit: String) {
        let (value, unit) = scaled(bitsPerSecond)
        return (number(value), units[unit])
    }

    /// "48,2 Мбит/с"
    static func text(_ bitsPerSecond: Double) -> String {
        let parts = parts(bitsPerSecond)
        return "\(parts.value) \(parts.unit)"
    }

    /// "48М" — for the Dynamic Island's narrow corner.
    static func compact(_ bitsPerSecond: Double) -> String {
        let (value, unit) = scaled(bitsPerSecond)
        return number(value) + compactUnits[unit]
    }

    private static func scaled(_ bitsPerSecond: Double) -> (Double, Int) {
        var value = max(bitsPerSecond, 0) / 1000
        var unit = 0
        while value >= 999.5, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        return (value, unit)
    }

    /// One decimal below 10, whole numbers above: "4,2", "48".
    private static func number(_ value: Double) -> String {
        let digits = value > 0 && value < 9.95 ? 1 : 0
        return value.formatted(.number.precision(.fractionLength(digits)).locale(locale))
    }
}

/// Traffic totals: "1,2 ГБ", "86 МБ".
enum Bytes {
    private static let units = ["Б", "КБ", "МБ", "ГБ", "ТБ"]
    private static let locale = Locale(identifier: "ru_RU")

    static func text(_ bytes: Int64) -> String {
        var value = Double(max(bytes, 0))
        var unit = 0
        while value >= 999.5, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        let digits = unit > 0 && value < 9.95 ? 1 : 0
        return value.formatted(.number.precision(.fractionLength(digits)).locale(locale)) + " " + units[unit]
    }
}

/// How long a session lasted: "1 ч 12 мин", "4 мин", "35 с".
enum SessionLength {
    static func text(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        guard total >= 60 else { return "\(total) с" }
        let hours = total / 3600
        let minutes = total % 3600 / 60
        guard hours > 0 else { return "\(minutes) мин" }
        return minutes == 0 ? "\(hours) ч" : "\(hours) ч \(minutes) мин"
    }
}

/// Where a server exits, read from its name. Panels name servers in many
/// ways — "🇫🇷 Париж", "DE-01", "[NL] Amsterdam", "Нидерланды 2" — so the
/// clues are tried from the most to the least certain.
enum Country {
    private static let russian = Locale(identifier: "ru_RU")
    private static let english = Locale(identifier: "en_US")

    static func code(inServerName name: String) -> String? {
        flagCode(name) ?? leadingCode(name) ?? namedCode(name)
    }

    /// 🇫🇷
    static func flag(_ code: String) -> String {
        String(code.uppercased().unicodeScalars.compactMap { scalar in
            (65...90).contains(scalar.value) ? UnicodeScalar(0x1F1E6 - 65 + scalar.value).map(Character.init) : nil
        })
    }

    /// "Франция"
    static func name(_ code: String) -> String {
        russian.localizedString(forRegionCode: code) ?? code
    }

    /// The server's name without flags ("🇳🇱 Амстердам #2" → "Амстердам #2").
    static func place(inServerName name: String) -> String {
        let scalars = name.unicodeScalars.filter { !(0x1F1E6...0x1F1FF).contains($0.value) }
        return String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    // MARK: - Clues

    /// A flag emoji: two regional-indicator letters.
    private static func flagCode(_ name: String) -> String? {
        let flags = name.unicodeScalars.filter { (0x1F1E6...0x1F1FF).contains($0.value) }
        guard flags.count >= 2 else { return nil }
        let letters = flags.prefix(2).compactMap { UnicodeScalar($0.value - 0x1F1E6 + 0x41).map(Character.init) }
        return letters.count == 2 ? String(letters) : nil
    }

    /// A capitalized code standing alone at the start: "DE-01", "[NL] …",
    /// "US | 3". Only codes panels actually use, so a name that merely starts
    /// with two capitals ("IN…", "IT …") isn't taken for a country.
    private static func leadingCode(_ name: String) -> String? {
        let trimmed = name.drop { " [(【{".contains($0) }
        let letters = trimmed.prefix(2)
        guard letters.count == 2,
              letters.allSatisfy({ $0.isASCII && $0.isUppercase }) else { return nil }
        if let next = trimmed.dropFirst(2).first, next.isLetter { return nil }
        let code = String(letters) == "UK" ? "GB" : String(letters)
        return panelCodes.contains(code) ? code : nil
    }

    /// A city or a country named in words, matched as whole words.
    private static func namedCode(_ name: String) -> String? {
        let text = " " + words(name) + " "
        for (city, code) in cities where text.contains(" \(city) ") {
            return code
        }
        for region in Locale.Region.isoRegions {
            let code = region.identifier
            guard code.count == 2, code.allSatisfy(\.isLetter) else { continue }
            for locale in [russian, english] {
                if let country = locale.localizedString(forRegionCode: code).map(words),
                   country.count >= 4, text.contains(" \(country) ") {
                    return code
                }
            }
        }
        return nil
    }

    /// Lowercased letters and digits, everything else a single space.
    private static func words(_ text: String) -> String {
        String(text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " })
            .split(separator: " ")
            .joined(separator: " ")
    }

    private static let panelCodes: Set<String> = [
        "AE", "AM", "AR", "AT", "AU", "AZ", "BE", "BG", "BR", "BY", "CA", "CH", "CL", "CY", "CZ",
        "DE", "DK", "EE", "ES", "FI", "FR", "GB", "GE", "GR", "HK", "HR", "HU", "ID", "IE", "IL",
        "IS", "JP", "KG", "KR", "KZ", "LT", "LU", "LV", "MD", "MX", "MY", "NL", "NO", "NZ", "PL",
        "PT", "RO", "RS", "RU", "SE", "SG", "SI", "SK", "TH", "TR", "TW", "UA", "US", "UZ", "VN", "ZA",
    ]

    /// Where VPN servers usually stand, in the spellings panels use.
    private static let cities: [(String, String)] = [
        ("амстердам", "NL"), ("amsterdam", "NL"), ("роттердам", "NL"), ("rotterdam", "NL"),
        ("франкфурт", "DE"), ("frankfurt", "DE"), ("берлин", "DE"), ("berlin", "DE"),
        ("мюнхен", "DE"), ("munich", "DE"), ("нюрнберг", "DE"), ("nuremberg", "DE"),
        ("фалькенштайн", "DE"), ("falkenstein", "DE"), ("дюссельдорф", "DE"), ("dusseldorf", "DE"),
        ("париж", "FR"), ("paris", "FR"), ("марсель", "FR"), ("marseille", "FR"),
        ("лондон", "GB"), ("london", "GB"), ("манчестер", "GB"), ("manchester", "GB"),
        ("хельсинки", "FI"), ("helsinki", "FI"), ("стокгольм", "SE"), ("stockholm", "SE"),
        ("осло", "NO"), ("oslo", "NO"), ("копенгаген", "DK"), ("copenhagen", "DK"),
        ("варшава", "PL"), ("warsaw", "PL"), ("рига", "LV"), ("riga", "LV"),
        ("таллин", "EE"), ("таллинн", "EE"), ("tallinn", "EE"), ("вильнюс", "LT"), ("vilnius", "LT"),
        ("прага", "CZ"), ("prague", "CZ"), ("вена", "AT"), ("vienna", "AT"),
        ("цюрих", "CH"), ("zurich", "CH"), ("женева", "CH"), ("geneva", "CH"),
        ("милан", "IT"), ("milan", "IT"), ("мадрид", "ES"), ("madrid", "ES"),
        ("барселона", "ES"), ("barcelona", "ES"), ("лиссабон", "PT"), ("lisbon", "PT"),
        ("дублин", "IE"), ("dublin", "IE"), ("брюссель", "BE"), ("brussels", "BE"),
        ("люксембург", "LU"), ("будапешт", "HU"), ("budapest", "HU"), ("бухарест", "RO"),
        ("bucharest", "RO"), ("софия", "BG"), ("sofia", "BG"), ("белград", "RS"), ("belgrade", "RS"),
        ("афины", "GR"), ("athens", "GR"), ("стамбул", "TR"), ("istanbul", "TR"),
        ("тбилиси", "GE"), ("tbilisi", "GE"), ("ереван", "AM"), ("yerevan", "AM"),
        ("баку", "AZ"), ("baku", "AZ"), ("алматы", "KZ"), ("almaty", "KZ"), ("астана", "KZ"), ("astana", "KZ"),
        ("ташкент", "UZ"), ("tashkent", "UZ"), ("бишкек", "KG"), ("bishkek", "KG"),
        ("кишинёв", "MD"), ("кишинев", "MD"), ("chisinau", "MD"), ("москва", "RU"), ("moscow", "RU"),
        ("санкт петербург", "RU"), ("петербург", "RU"), ("saint petersburg", "RU"),
        ("токио", "JP"), ("tokyo", "JP"), ("осака", "JP"), ("osaka", "JP"), ("сеул", "KR"), ("seoul", "KR"),
        ("сингапур", "SG"), ("гонконг", "HK"), ("hong kong", "HK"), ("тайбэй", "TW"), ("taipei", "TW"),
        ("дубай", "AE"), ("dubai", "AE"), ("тель авив", "IL"), ("tel aviv", "IL"),
        ("нью йорк", "US"), ("new york", "US"), ("лос анджелес", "US"), ("los angeles", "US"),
        ("майами", "US"), ("miami", "US"), ("чикаго", "US"), ("chicago", "US"), ("даллас", "US"),
        ("dallas", "US"), ("сиэтл", "US"), ("seattle", "US"), ("сан франциско", "US"),
        ("san francisco", "US"), ("сан хосе", "US"), ("san jose", "US"), ("ашберн", "US"), ("ashburn", "US"),
        ("торонто", "CA"), ("toronto", "CA"), ("монреаль", "CA"), ("montreal", "CA"),
        ("ванкувер", "CA"), ("vancouver", "CA"), ("сидней", "AU"), ("sydney", "AU"),
        ("мельбурн", "AU"), ("melbourne", "AU"), ("сан паулу", "BR"), ("sao paulo", "BR"),
        ("йоханнесбург", "ZA"), ("johannesburg", "ZA"),
    ]
}
