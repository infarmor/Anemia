import Foundation

/// Latency, download and upload through whatever route this process's
/// traffic takes — the VPN when it is on — against Cloudflare's speed-test
/// endpoints (the ones speed.cloudflare.com itself uses).
public enum SpeedTester {
    public struct Result: Codable, Equatable, Sendable {
        /// Milliseconds.
        public var latency: Int?
        /// Bits per second.
        public var download: Double
        public var upload: Double?
    }

    public enum Phase: Sendable, Equatable {
        case latency, download, upload
    }

    public enum Event: Sendable, Equatable {
        /// A phase's current rate, bits per second, four times a second.
        case live(Phase, Double)
        /// A phase's result: milliseconds for latency, bits per second otherwise.
        case measured(Phase, Double)
    }

    public struct Limits: Sendable {
        /// Each direction runs this long at most…
        public var window: TimeInterval = 10
        /// …or until this much has moved: a fast link would otherwise burn
        /// most of a gigabyte on one test.
        public var downloadBudget: Int64 = 150_000_000
        public var uploadBudget: Int64 = 75_000_000
        /// One TCP stream rarely fills a fast link, least of all through a tunnel.
        public var streams = 3

        public init() {}
    }

    public static let base = URL(string: "https://speed.cloudflare.com")!

    /// `events` hears each phase's live rate and, as it ends, its result.
    /// `proxy`: send the test through a local SOCKS proxy.
    public static func run(limits: Limits = Limits(), proxy: LocalProxy? = nil,
                           events: @escaping @Sendable (Event) -> Void) async throws -> Result {
        events(.live(.latency, 0))
        let latency = try await measureLatency(proxy: proxy)
        events(.measured(.latency, Double(latency)))
        let download = try await measure(upload: false, limits: limits, proxy: proxy) { events(.live(.download, $0)) }
        events(.measured(.download, download))
        let upload = try? await measure(upload: true, limits: limits, proxy: proxy) { events(.live(.upload, $0)) }
        if let upload { events(.measured(.upload, upload)) }
        return Result(latency: latency, download: download, upload: upload)
    }

    /// Median of five small requests over one kept-alive connection; the
    /// first, which also sets the connection up, doesn't count.
    static func measureLatency(proxy: LocalProxy? = nil) async throws -> Int {
        let session = URLSession(configuration: LocalProxy.sessionConfiguration(proxy))
        defer { session.finishTasksAndInvalidate() }
        let url = base.appendingPathComponent("__down").appending(queryItems: [URLQueryItem(name: "bytes", value: "0")])
        var times: [Double] = []
        for attempt in 0..<6 {
            let start = Date()
            let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
            _ = try await session.data(for: request)
            if attempt > 0 { times.append(Date().timeIntervalSince(start) * 1000) }
        }
        times.sort()
        return Int(times[times.count / 2].rounded())
    }

    /// One direction over parallel connections: the rate over the window
    /// after the first second, when TCP is still ramping up. The endpoints
    /// serve at most 50 MB per request, so finished transfers are replaced
    /// until the window or the budget runs out.
    static func measure(upload: Bool, limits: Limits, proxy: LocalProxy? = nil,
                        progress: @Sendable (Double) -> Void) async throws -> Double {
        let meter = Meter()
        let session = URLSession(configuration: LocalProxy.sessionConfiguration(proxy), delegate: meter, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let payload = upload ? Data(count: 25_000_000) : Data()
        let downURL = base.appendingPathComponent("__down").appending(queryItems: [URLQueryItem(name: "bytes", value: "50000000")])
        let upURL = base.appendingPathComponent("__up")
        func makeTask() -> URLSessionTask {
            if upload {
                var request = URLRequest(url: upURL, timeoutInterval: 30)
                request.httpMethod = "POST"
                request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                return session.uploadTask(with: request, from: payload)
            }
            return session.dataTask(with: URLRequest(url: downURL, timeoutInterval: 30))
        }
        var tasks = (0..<max(limits.streams, 1)).map { _ in makeTask() }
        tasks.forEach { $0.resume() }

        let start = Date()
        let budget = upload ? limits.uploadBudget : limits.downloadBudget
        var warm: (time: Date, bytes: Int64)?
        var previous = (time: start, bytes: Int64(0))
        var live = 0.0
        while Date().timeIntervalSince(start) < limits.window, meter.bytes < budget {
            try await Task.sleep(for: .milliseconds(250))
            if meter.error != nil, meter.bytes == 0 { break }
            for index in tasks.indices where tasks[index].state == .completed {
                tasks[index] = makeTask()
                tasks[index].resume()
            }
            let now = Date()
            let bytes = meter.bytes
            let rate = Double(bytes - previous.bytes) * 8 / max(now.timeIntervalSince(previous.time), 0.05)
            live = live == 0 ? rate : live * 0.6 + rate * 0.4
            progress(live)
            previous = (now, bytes)
            if warm == nil, now.timeIntervalSince(start) >= 1 { warm = (now, bytes) }
        }
        tasks.forEach { $0.cancel() }

        let end = Date()
        let total = meter.bytes
        if total == 0 { throw meter.error ?? URLError(.zeroByteResource) }
        let from = warm ?? (start, 0)
        return Double(total - from.bytes) * 8 / max(end.timeIntervalSince(from.time), 0.25)
    }
}

/// Counts bytes as they move, over all of a session's transfers.
private final class Meter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var count: Int64 = 0
    private var failure: (any Error)?

    var bytes: Int64 { lock.withLock { count } }
    var error: (any Error)? { lock.withLock { failure } }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        // An error page isn't speed.
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            lock.withLock { failure = URLError(.badServerResponse) }
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock { count += Int64(data.count) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        lock.withLock { count += bytesSent }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let error, (error as? URLError)?.code != .cancelled else { return }
        lock.withLock { failure = error }
    }
}
