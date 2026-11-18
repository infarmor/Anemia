using System.Net;
using AnemiaCore;
using Xunit;

namespace AnemiaCoreTests;

public sealed class PanelDeviceTests : IDisposable
{
    private const string DeviceId = "270DD26E-160D-4257-B8AC-654800E12F24";
    private static readonly Uri Panel = new("https://panel.example/subscription");
    private readonly string _directory = Path.Combine(Path.GetTempPath(), $"anemia-device-{Guid.NewGuid():N}");

    [Fact]
    public async Task FirstUsePersistsOneRandomIdAcrossInstancesAndRaces()
    {
        var path = Path.Combine(_directory, "first", "subscription-device-id");
        var ids = await Task.WhenAll(Enumerable.Range(0, 8)
            .Select(_ => Task.Run(() => new SubscriptionDeviceIdentity(path).GetOrCreate())));
        var id = Assert.Single(ids.Distinct());
        Assert.True(Guid.TryParseExact(id, "D", out var parsed));
        Assert.NotEqual(Guid.Empty, parsed);
        Assert.Equal(id, File.ReadAllText(path));
        Assert.Equal(id, new SubscriptionDeviceIdentity(path).GetOrCreate());
        Assert.NotEqual(id, new SubscriptionDeviceIdentity(Path.Combine(_directory, "second", "id")).GetOrCreate());
        Assert.Single(Directory.GetFiles(Path.GetDirectoryName(path)!));
    }

    [Fact]
    public void InvalidExistingIdIsPreserved()
    {
        Directory.CreateDirectory(_directory);
        var path = Path.Combine(_directory, "device-id");
        File.WriteAllText(path, "unreadable device ID");
        Assert.Throws<IOException>(() => new SubscriptionDeviceIdentity(path).GetOrCreate());
        Assert.Equal("unreadable device ID", File.ReadAllText(path));
    }

    [Theory]
    [InlineData("https://other.example/next")]
    [InlineData("https://panel.example:8443/next")]
    public async Task IdentityStaysInOriginalOriginAndDoesNotReturnAfterCrossing(string other)
    {
        using var handler = new ScriptedHandler(Redirect("/same"), Redirect(other), Redirect(Panel.AbsoluteUri), Ok());
        var loaded = 0;
        var result = await PanelClient.FetchAsync(Panel, () => { loaded++; return DeviceId; }, default, handler);

        Assert.Equal("subscription body", result.Body);
        Assert.Equal(1, loaded);
        Assert.Equal(new string?[] { DeviceId, DeviceId, null, null }, handler.Requests.Select(r => r.DeviceId));
        Assert.Equal(new string?[] { "Windows", "Windows", null, null }, handler.Requests.Select(r => r.DeviceOs));
        Assert.All(handler.Requests, r => Assert.Equal(PanelClient.UserAgent, r.UserAgent));
    }

    [Fact]
    public async Task PlainHttpCanUpgradeButDoesNotSendAnId()
    {
        using var handler = new ScriptedHandler(Redirect(Panel.AbsoluteUri), Ok());
        var result = await PanelClient.FetchAsync(new Uri("http://panel.example/subscription"),
            () => throw new InvalidOperationException("Plain HTTP must not load the device ID."), default, handler);

        Assert.True(result.IsSuccessStatusCode);
        Assert.All(handler.Requests, r => Assert.Null(r.DeviceId));
    }

    [Fact]
    public async Task HttpsDoesNotFollowAPlainHttpRedirect()
    {
        using var handler = new ScriptedHandler(Redirect("http://panel.example/subscription"));
        var result = await PanelClient.FetchAsync(Panel, () => DeviceId, default, handler);

        Assert.Equal(HttpStatusCode.Found, result.StatusCode);
        Assert.Equal(DeviceId, Assert.Single(handler.Requests).DeviceId);
    }

    [Theory]
    [InlineData(HttpStatusCode.OK, "X-HwId-MaX-DeViCeS-ReAcHeD")]
    [InlineData(HttpStatusCode.Forbidden, "x-hwid-limit")]
    public async Task DeviceLimitDiscardsEvenSuccessfulBodies(HttpStatusCode status, string header)
    {
        var response = Ok();
        response.StatusCode = status;
        response.Headers.Add(header, "TrUe");
        using var handler = new ScriptedHandler(response);
        var result = await PanelClient.FetchAsync(Panel, () => DeviceId, default, handler);

        Assert.Equal(PanelRefusal.DeviceLimit, result.Refusal);
        Assert.Null(result.Body);
    }

    [Fact]
    public async Task ExplicitDeviceIdRefusalTakesPrecedenceOverTheLegacyFlag()
    {
        var response = new HttpResponseMessage(HttpStatusCode.NotFound);
        response.Headers.Add("x-hwid-not-supported", "TRUE");
        response.Headers.Add("x-hwid-limit", "true");
        using var handler = new ScriptedHandler(response);
        var result = await PanelClient.FetchAsync(Panel, () => DeviceId, default, handler);

        Assert.Equal(PanelRefusal.DeviceIdRequired, result.Refusal);
        Assert.Null(result.Body);
    }

    [Fact]
    public async Task ActiveHintAndFalseLimitDoNotRefuseSubscription()
    {
        var response = Ok();
        response.Headers.Add("x-hwid-active", "true");
        response.Headers.Add("x-hwid-limit", "false");
        using var handler = new ScriptedHandler(response);
        var result = await PanelClient.FetchAsync(Panel, () => DeviceId, default, handler);

        Assert.Equal(PanelRefusal.None, result.Refusal);
        Assert.Equal("subscription body", result.Body);
    }

    public void Dispose()
    {
        if (!Directory.Exists(_directory)) return;
        foreach (var file in Directory.EnumerateFiles(_directory, "*", SearchOption.AllDirectories)) File.Delete(file);
        foreach (var child in Directory.EnumerateDirectories(_directory)) Directory.Delete(child);
        Directory.Delete(_directory);
    }

    private static HttpResponseMessage Ok() => new(HttpStatusCode.OK)
    {
        Content = new StringContent("subscription body"),
    };

    private static HttpResponseMessage Redirect(string location)
    {
        var response = new HttpResponseMessage(HttpStatusCode.Found);
        response.Headers.Location = new Uri(location, UriKind.RelativeOrAbsolute);
        return response;
    }

    private sealed record SentRequest(string? DeviceId, string? DeviceOs, string UserAgent);

    private sealed class ScriptedHandler(params HttpResponseMessage[] responses) : HttpMessageHandler
    {
        private int _next;
        public List<SentRequest> Requests { get; } = new();

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            string? Header(string name) => request.Headers.TryGetValues(name, out var values) ? values.Single() : null;
            Requests.Add(new SentRequest(Header("x-hwid"), Header("x-device-os"), request.Headers.UserAgent.ToString()));
            return Task.FromResult(responses[_next++]);
        }
    }
}
