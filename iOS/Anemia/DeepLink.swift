import Foundation

/// Links that open Anemia with something to import: the "Добавить в
/// приложение" buttons of VPN providers (`anemia://import/…`), and share
/// links themselves when iOS hands them to Anemia.
enum DeepLink {
    static let shareSchemes: Set<String> = ["vless", "vmess", "trojan", "ss", "hysteria2", "hy2"]

    /// The text to import, or nil for links that only open the app.
    static func importText(from url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased() else { return nil }
        if shareSchemes.contains(scheme) {
            return url.absoluteString
        }
        guard scheme == "anemia" else { return nil }
        // anemia://import?url=…, …/add?url=…
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let value = components.queryItems?.first(where: { ["url", "link", "config", "data"].contains($0.name.lowercased()) })?.value,
           !value.isEmpty {
            return value
        }
        // anemia://import/https://…, anemia://add/vless://…, anemia://import/<base64>
        let text = url.absoluteString
        for action in ["import", "add", "install-config", "subscribe", "sub"] {
            let prefix = "anemia://\(action)/"
            guard text.lowercased().hasPrefix(prefix) else { continue }
            let rest = String(text.dropFirst(prefix.count))
            let decoded = rest.removingPercentEncoding ?? rest
            return decoded.isEmpty ? nil : decoded
        }
        return nil
    }
}
