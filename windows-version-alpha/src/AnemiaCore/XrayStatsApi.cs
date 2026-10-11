using System.Net.Sockets;
using System.Text;

namespace AnemiaCore;

/// <summary>One counter from Xray's Stats API.</summary>
public readonly record struct XrayStat(string Name, long Value);

/// <summary>
/// Native gRPC-over-h2c client for Xray's StatsService.QueryStats.
/// Replaces per-poll `xray api statsquery` forks: every sample used to spawn
/// the whole ~28 MB engine binary just to read two counters. This speaks the
/// exact minimal subset of HTTP/2 one unary RPC needs — client preface,
/// SETTINGS (+WINDOW_UPDATE), HPACK literal headers without indexing or
/// Huffman, a DATA frame, and a frame-parse loop — plus a protobuf varint walk
/// of QueryStatsResponse.
/// One blocking call per invocation; run it off the UI thread. Null means the
/// RPC did not complete within the timeout (connection refused, RST, GOAWAY,
/// slow peer) — callers fall back to the CLI path.
/// </summary>
public static class XrayStatsApi
{
    /// <summary>Query cumulative counter values. `pattern` is the protobuf
    /// query pattern (e.g. "outbound&gt;&gt;&gt;proxy&gt;&gt;&gt;"); null queries every
    /// counter — keep it narrow, the response fits the default flow-control
    /// window.</summary>
    public static List<XrayStat>? Query(string host = "127.0.0.1", ushort port = default, string? pattern = null, TimeSpan? timeout = null)
    {
        if (port == default) return null;
        timeout ??= TimeSpan.FromSeconds(6);
        try
        {
            using var cts = new CancellationTokenSource(timeout.Value);
            var result = Run(host, port, pattern, cts.Token);
            // gRPC response frame: 1-byte compression flag (0) + 4-byte BE length.
            if (result is null || result.Count < 5 || result[0] != 0x00) return null;

            var plen = 0;
            for (var i = 1; i <= 4; i++) plen = (plen << 8) | result[i];
            var proto = result.Skip(5).ToArray();
            if (plen != proto.Length) return null;

            return ParseProtobuf(proto);
        }
        catch (OperationCanceledException)
        {
            return null;
        }
        catch (SocketException)
        {
            return null;
        }
        catch (IOException)
        {
            return null;
        }
        catch (ObjectDisposedException)
        {
            return null;
        }
    }

    private static List<byte>? Run(string host, ushort port, string? pattern, CancellationToken ct)
    {
        using var client = new TcpClient();
        client.NoDelay = true;
        using (var connectCts = CancellationTokenSource.CreateLinkedTokenSource(ct))
        using (connectCts.Token.Register(() => client.Close()))
        {
            client.ConnectAsync(host, port, connectCts.Token).AsTask().Wait(ct);
        }
        using var stream = client.GetStream();

        var request = RequestBytes(port, pattern);
        stream.Write(request.ToArray(), 0, request.Count);
        stream.Flush();

        // `wire` accumulates the raw socket byte stream; complete HTTP/2 frames
        // are peeled off it; DATA payloads append to `message`.
        var wire = new List<byte>();
        var message = new List<byte>();
        var buffer = new byte[1 << 16];
        var done = false;
        while (!done && !ct.IsCancellationRequested)
        {
            var n = stream.Read(buffer, 0, buffer.Length);
            if (n <= 0) break; // connection closed — the response is what it is
            wire.AddRange(buffer.AsSpan(0, n));

            // Peel complete frames off the front of `wire`.
            while (wire.Count >= 9)
            {
                var len = (wire[0] << 16) | (wire[1] << 8) | wire[2];
                if (wire.Count < 9 + len) break;
                var type = wire[3];
                var flags = wire[4];
                var payload = wire.GetRange(9, len);
                wire.RemoveRange(0, 9 + len);

                switch (type)
                {
                    case 0x4: // SETTINGS — ACK anything that isn't already an ACK
                        if ((flags & 0x1) == 0)
                            stream.Write(Frame(0x4, 0x1, 0, new List<byte>()).ToArray(), 0, 9);
                        break;
                    case 0x0: // DATA
                        message.AddRange(payload);
                        if ((flags & 0x1) != 0) done = true;   // END_STREAM
                        break;
                    case 0x1: // HEADERS (initial)
                    case 0x9: // trailers
                        if ((flags & 0x1) != 0) done = true;   // END_STREAM on trailers
                        break;
                    case 0x3: // RST_STREAM
                    case 0x7: // GOAWAY
                        return message.Count >= 5 ? message : null;
                    default: // PING, WINDOW_UPDATE, …
                        break;
                }
                if (done) break;
            }
        }
        return message.Count >= 5 ? message : null;
    }

    // MARK: - Wire format

    /// <summary>Preface + SETTINGS + large WINDOW_UPDATE + HEADERS +
    /// DATA(END_STREAM). The WINDOW_UPDATE raises the connection flow window
    /// past any realistic response so the parse loop never stalls waiting for
    /// credit we never grant.</summary>
    private static List<byte> RequestBytes(ushort port, string? pattern)
    {
        var outBytes = new List<byte>(Encoding.ASCII.GetBytes("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"));
        outBytes.AddRange(Frame(0x4, 0, 0, new List<byte>()));                          // SETTINGS (empty)
        outBytes.AddRange(Frame(0x8, 0, 0, new List<byte> { 0x00, 0x0F, 0x42, 0x40 })); // +1 MiB
        var headers = new List<byte>();
        headers.AddRange(Header(":method", "POST"));
        headers.AddRange(Header(":scheme", "http"));
        headers.AddRange(Header(":path", "/xray.app.stats.command.StatsService/QueryStats"));
        headers.AddRange(Header(":authority", $"127.0.0.1:{port}"));
        headers.AddRange(Header("content-type", "application/grpc"));
        headers.AddRange(Header("te", "trailers"));
        headers.AddRange(Header("user-agent", "anemia-stats/1"));
        outBytes.AddRange(Frame(0x1, 0x4, 1, headers));                                 // HEADERS + END_HEADERS
        // QueryStatsRequest { string pattern = 1 } — empty message when null.
        var body = new List<byte>();
        if (pattern is not null)
        {
            var bytes = Encoding.UTF8.GetBytes(pattern);
            body.Add(0x0A);                                                             // field 1, wire 2
            EncodeVarint(bytes.Length, body);
            body.AddRange(bytes);
        }
        var grpc = new List<byte> { 0x00 };                                             // uncompressed
        grpc.Add((byte)((body.Count >> 24) & 0xFF));                                    // gRPC: 4-byte BE length
        grpc.Add((byte)((body.Count >> 16) & 0xFF));
        grpc.Add((byte)((body.Count >> 8) & 0xFF));
        grpc.Add((byte)(body.Count & 0xFF));
        grpc.AddRange(body);
        outBytes.AddRange(Frame(0x0, 0x1, 1, grpc));                                    // DATA + END_STREAM
        return outBytes;
    }

    private static void EncodeVarint(long v0, List<byte> d)
    {
        ulong v = (ulong)v0;
        while (true)
        {
            var b = (byte)(v & 0x7F);
            v >>= 7;
            if (v != 0) b |= 0x80;
            d.Add(b);
            if (v == 0) break;
        }
    }

    /// <summary>24-bit big-endian length + type + flags + 32-bit stream id.</summary>
    private static List<byte> Frame(byte type, byte flags, uint stream, List<byte> payload)
    {
        var d = new List<byte>(9 + payload.Count)
        {
            (byte)((payload.Count >> 16) & 0xFF),
            (byte)((payload.Count >> 8) & 0xFF),
            (byte)(payload.Count & 0xFF),
            type,
            flags,
            (byte)((stream >> 24) & 0xFF),
            (byte)((stream >> 16) & 0xFF),
            (byte)((stream >> 8) & 0xFF),
            (byte)(stream & 0xFF),
        };
        d.AddRange(payload);
        return d;
    }

    /// <summary>HPACK literal header field without indexing, new name, no
    /// Huffman — a stateless encoding both sides can decode without table
    /// bookkeeping.</summary>
    private static List<byte> Header(string name, string value)
    {
        static List<byte> Str(string s)
        {
            var b = Encoding.UTF8.GetBytes(s);
            var d = new List<byte>();
            if (b.Length < 127)
            {
                d.Add((byte)b.Length);
            }
            else
            {
                d.Add(0x7F);
                var n = b.Length - 127;
                while (n >= 128) { d.Add((byte)((n & 0x7F) | 0x80)); n >>= 7; }
                d.Add((byte)n);
            }
            d.AddRange(b);
            return d;
        }
        var d = new List<byte> { 0x00 };
        d.AddRange(Str(name));
        d.AddRange(Str(value));
        return d;
    }

    // MARK: - Protobuf

    /// <summary>QueryStatsResponse { repeated Stat stat = 1 }, Stat { string
    /// name = 1; int64 value = 2 }. Walks only the fields the response can
    /// contain; truncated/garbage input returns whatever parsed out.</summary>
    public static List<XrayStat> ParseProtobuf(byte[] data)
    {
        var stats = new List<XrayStat>();
        var i = 0;

        static ulong Varint(byte[] d, ref int i)
        {
            ulong v = 0;
            var shift = 0;
            while (i < d.Length)
            {
                var b = d[i++];
                v |= (ulong)(b & 0x7F) << shift;
                if ((b & 0x80) == 0) break;
                shift += 7;
            }
            return v;
        }

        static byte[]? LengthDelimited(byte[] d, ref int i)
        {
            var len = (long)Varint(d, ref i);
            if (len < 0 || i + len > d.Length) return null;
            var sub = d[i..(int)(i + len)];
            i += (int)len;
            return sub;
        }

        while (i < data.Length)
        {
            var tag = Varint(data, ref i);
            if (tag == (1UL << 3 | 2))                                      // repeated Stat
            {
                var sub = LengthDelimited(data, ref i);
                if (sub is null) return stats;
                var j = 0;
                var name = "";
                long value = 0;
                while (j < sub.Length)
                {
                    var t = Varint(sub, ref j);
                    if (t == (1UL << 3 | 2))
                    {
                        var s = LengthDelimited(sub, ref j);
                        if (s is null) return stats;
                        name = Encoding.UTF8.GetString(s);
                    }
                    else if (t == (2UL << 3 | 0))
                    {
                        value = unchecked((long)Varint(sub, ref j));
                    }
                    else
                    {
                        return stats;                                       // unknown → stop, keep what we have
                    }
                }
                stats.Add(new XrayStat(name, value));
            }
            else
            {
                return stats;                                               // not a Stat field → done
            }
        }
        return stats;
    }
}