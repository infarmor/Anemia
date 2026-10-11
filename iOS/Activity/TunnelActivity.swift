import ActivityKit
import Foundation

/// The running tunnel as a Live Activity: the exit country on the left, the
/// live speed on the right, a speed graph and the session's numbers below.
/// The app starts it on connect and feeds it (see LiveActivityController).
///
/// Everything lives in the content state, the server too: switching servers
/// updates the same activity, which iOS lets the app do from the background —
/// starting a new one it mostly doesn't.
struct TunnelActivityAttributes: ActivityAttributes, Hashable {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable {
            case connecting
            case connected
            /// The tunnel dropped and iOS is bringing it back (on-demand).
            case reconnecting
            /// The "Быстрее" button: pinging the servers.
            case searching
            /// The session is over; the activity shows its summary.
            case ended
        }

        var phase: Phase
        /// ISO region code of the exit; nil when the server's name doesn't reveal it.
        var countryCode: String?
        /// The country, or the server's own name when its country is unknown.
        var title: String
        /// "Париж · VLESS · Reality"
        var subtitle: String
        /// Bits per second, lightly smoothed.
        var download: Double
        var upload: Double
        /// The graph: recent speeds, oldest first, in kbit/s.
        var downHistory: [Int]
        var upHistory: [Int]
        /// When the session started; reconnects don't reset it.
        var connectedSince: Date
        var endedAt: Date?
        /// Bytes this session, reconnects included.
        var received: Int64
        var sent: Int64
        /// Round trip to the server, ms.
        var latency: Int?
        /// A one-off line in place of the numbers ("Этот сервер и так самый быстрый").
        var note: String?

        init(phase: Phase, countryCode: String?, title: String, subtitle: String,
             download: Double = 0, upload: Double = 0,
             downHistory: [Int] = [], upHistory: [Int] = [],
             connectedSince: Date, endedAt: Date? = nil,
             received: Int64 = 0, sent: Int64 = 0,
             latency: Int? = nil, note: String? = nil) {
            self.phase = phase
            self.countryCode = countryCode
            self.title = title
            self.subtitle = subtitle
            self.download = download
            self.upload = upload
            self.downHistory = downHistory
            self.upHistory = upHistory
            self.connectedSince = connectedSince
            self.endedAt = endedAt
            self.received = received
            self.sent = sent
            self.latency = latency
            self.note = note
        }

        /// Tolerant: an activity started by an older build carries fewer
        /// fields (and `connecting` instead of a phase).
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let phase = try c.decodeIfPresent(Phase.self, forKey: .phase) {
                self.phase = phase
            } else {
                let connecting = try c.decodeIfPresent(Bool.self, forKey: .connecting) ?? false
                self.phase = connecting ? .connecting : .connected
            }
            countryCode = try c.decodeIfPresent(String.self, forKey: .countryCode)
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Anemia"
            subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
            download = try c.decodeIfPresent(Double.self, forKey: .download) ?? 0
            upload = try c.decodeIfPresent(Double.self, forKey: .upload) ?? 0
            downHistory = try c.decodeIfPresent([Int].self, forKey: .downHistory) ?? []
            upHistory = try c.decodeIfPresent([Int].self, forKey: .upHistory) ?? []
            connectedSince = try c.decodeIfPresent(Date.self, forKey: .connectedSince) ?? .now
            endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
            received = try c.decodeIfPresent(Int64.self, forKey: .received) ?? 0
            sent = try c.decodeIfPresent(Int64.self, forKey: .sent) ?? 0
            latency = try c.decodeIfPresent(Int.self, forKey: .latency)
            note = try c.decodeIfPresent(String.self, forKey: .note)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(phase, forKey: .phase)
            try c.encodeIfPresent(countryCode, forKey: .countryCode)
            try c.encode(title, forKey: .title)
            try c.encode(subtitle, forKey: .subtitle)
            try c.encode(download, forKey: .download)
            try c.encode(upload, forKey: .upload)
            try c.encode(downHistory, forKey: .downHistory)
            try c.encode(upHistory, forKey: .upHistory)
            try c.encode(connectedSince, forKey: .connectedSince)
            try c.encodeIfPresent(endedAt, forKey: .endedAt)
            try c.encode(received, forKey: .received)
            try c.encode(sent, forKey: .sent)
            try c.encodeIfPresent(latency, forKey: .latency)
            try c.encodeIfPresent(note, forKey: .note)
        }

        private enum CodingKeys: String, CodingKey {
            case phase, connecting, countryCode, title, subtitle, download, upload
            case downHistory, upHistory, connectedSince, endedAt, received, sent, latency, note
        }

        /// How many graph points the activity keeps: two minutes at the
        /// feed's 4 s sample. Fewer points also mean fewer bytes per update
        /// and a cheaper path for the widget to draw — the island is
        /// redrawn on every one of them.
        static let historyLength = 30
    }
}
