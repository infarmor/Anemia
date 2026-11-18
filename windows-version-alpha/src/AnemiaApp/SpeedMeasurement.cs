using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;

namespace AnemiaApp;

/// <summary>The same Cloudflare endpoints, window and transfer budgets as LoaderCore.SpeedTester.</summary>
internal static class SpeedMeasurement
{
    internal enum Phase { Latency, Download, Upload }
    internal record struct Reading(Phase Phase, double Value, bool Complete = false);
    internal record struct Result(int Latency, double Download, double? Upload);

    private const string BaseUrl = "https://speed.cloudflare.com";
    private static readonly byte[] UploadBlock = new byte[64 * 1024];

    public static async Task<Result> RunAsync(IProgress<Reading> progress, CancellationToken cancellationToken)
    {
        using var handler = new SocketsHttpHandler { UseProxy = false, AllowAutoRedirect = false };
        using var client = new HttpClient(handler) { Timeout = Timeout.InfiniteTimeSpan };
        var latency = await LatencyAsync(client, progress, cancellationToken);
        var download = await MeasureAsync(client, Phase.Download, 50_000_000, progress, cancellationToken);
        double? upload;
        try
        {
            upload = await MeasureAsync(client, Phase.Upload, 25_000_000, progress, cancellationToken);
        }
        catch (Exception error) when (error is HttpRequestException or IOException)
        {
            cancellationToken.ThrowIfCancellationRequested();
            upload = null;
        }
        return new Result(latency, download, upload);
    }

    private static async Task<int> LatencyAsync(HttpClient client, IProgress<Reading> progress, CancellationToken ct)
    {
        progress.Report(new Reading(Phase.Latency, 0));
        var samples = new int[5];
        for (var attempt = 0; attempt <= samples.Length; attempt++)
        {
            using var request = CancellationTokenSource.CreateLinkedTokenSource(ct);
            request.CancelAfter(TimeSpan.FromSeconds(8));
            var time = Stopwatch.StartNew();
            using var response = await client.GetAsync(BaseUrl + "/__down?bytes=0", request.Token);
            response.EnsureSuccessStatusCode();
            if (attempt != 0) samples[attempt - 1] = (int)Math.Round(time.Elapsed.TotalMilliseconds);
        }
        Array.Sort(samples);
        var median = samples[samples.Length / 2];
        progress.Report(new Reading(Phase.Latency, median, true));
        return median;
    }

    private static async Task<double> MeasureAsync(HttpClient client, Phase phase, int limit,
        IProgress<Reading> progress, CancellationToken ct)
    {
        using var window = CancellationTokenSource.CreateLinkedTokenSource(ct);
        window.CancelAfter(TimeSpan.FromSeconds(10));
        long bytes = 0;
        void Count(int count) => Interlocked.Add(ref bytes, count);

        var clock = Stopwatch.StartNew();
        var streams = Task.WhenAll(Enumerable.Range(0, 3).Select(_ => phase == Phase.Upload
            ? UploadAsync(client, limit, Count, window.Token)
            : DownloadAsync(client, limit, Count, window.Token)));

        var prior = 0L;
        var priorTime = 0.0;
        var warmBytes = 0L;
        var warmTime = 0.0;
        progress.Report(new Reading(phase, 0));
        while (!streams.IsCompleted)
        {
            await Task.WhenAny(streams, Task.Delay(250, ct));
            if (ct.IsCancellationRequested) break;
            var elapsed = clock.Elapsed.TotalSeconds;
            var total = Interlocked.Read(ref bytes);
            progress.Report(new Reading(phase, (total - prior) * 8 / Math.Max(0.05, elapsed - priorTime)));
            if (warmTime == 0 && elapsed >= 1)
                (warmBytes, warmTime) = (total, elapsed);
            (prior, priorTime) = (total, elapsed);
        }
        try { await streams; }
        catch (OperationCanceledException) when (window.IsCancellationRequested) { }
        ct.ThrowIfCancellationRequested();
        var measured = Interlocked.Read(ref bytes);
        if (measured == 0) throw new IOException("The speed test transferred no bytes.");
        if (measured <= warmBytes) (warmBytes, warmTime) = (0, 0);
        var result = (measured - warmBytes) * 8 / Math.Max(0.05, clock.Elapsed.TotalSeconds - warmTime);
        progress.Report(new Reading(phase, result, true));
        return result;
    }

    private static async Task DownloadAsync(HttpClient client, int limit, Action<int> count, CancellationToken ct)
    {
        using var response = await client.GetAsync(BaseUrl + "/__down?bytes=" + limit,
            HttpCompletionOption.ResponseHeadersRead, ct);
        response.EnsureSuccessStatusCode();
        await using var stream = await response.Content.ReadAsStreamAsync(ct);
        var buffer = new byte[64 * 1024];
        while (limit > 0)
        {
            var read = await stream.ReadAsync(buffer.AsMemory(0, Math.Min(buffer.Length, limit)), ct);
            if (read == 0) break;
            limit -= read;
            count(read);
        }
    }

    private static async Task UploadAsync(HttpClient client, int limit, Action<int> count, CancellationToken ct)
    {
        using var payload = new Payload(limit, count);
        using var response = await client.PostAsync(BaseUrl + "/__up", payload, ct);
        response.EnsureSuccessStatusCode();
    }

    private sealed class Payload : HttpContent
    {
        private readonly int _length;
        private readonly Action<int> _count;

        public Payload(int length, Action<int> count)
        {
            _length = length;
            _count = count;
            Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
        }

        protected override Task SerializeToStreamAsync(Stream stream, TransportContext? context) =>
            SerializeToStreamAsync(stream, context, CancellationToken.None);

        protected override async Task SerializeToStreamAsync(Stream stream, TransportContext? context,
            CancellationToken cancellationToken)
        {
            int remaining = _length;
            while (remaining > 0)
            {
                var size = Math.Min(remaining, UploadBlock.Length);
                await stream.WriteAsync(UploadBlock.AsMemory(0, size), cancellationToken);
                _count(size);
                remaining -= size;
            }
        }

        protected override bool TryComputeLength(out long length)
        {
            length = _length;
            return true;
        }
    }
}
