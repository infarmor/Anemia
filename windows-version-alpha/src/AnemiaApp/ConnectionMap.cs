using System.Globalization;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using AnemiaCore;
using Brush = System.Windows.Media.Brush;
using Point = System.Windows.Point;

namespace AnemiaApp;

public sealed class ConnectionMap : FrameworkElement
{
    public static readonly DependencyProperty LandProperty = DependencyProperty.Register(
        nameof(Land), typeof(Brush), typeof(ConnectionMap),
        new FrameworkPropertyMetadata(null, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty AccentProperty = DependencyProperty.Register(
        nameof(Accent), typeof(Brush), typeof(ConnectionMap),
        new FrameworkPropertyMetadata(null, FrameworkPropertyMetadataOptions.AffectsRender));

    public Brush? Land { get => (Brush?)GetValue(LandProperty); set => SetValue(LandProperty, value); }
    public Brush? Accent { get => (Brush?)GetValue(AccentProperty); set => SetValue(AccentProperty, value); }

    private static readonly Lazy<MapGeo> Data = new(Load);
    private string? _country;
    private string? _origin;
    private string? _label;
    private IReadOnlyList<string> _countries = Array.Empty<string>();
    private Dictionary<string, Point> _markers = new();
    private string? _hoveredCountry;
    private bool _connected;

    public event Action<string>? CountryPicked;
    public Func<string, string>? CountryDetails { get; set; }
    public bool CanPick { get; set; }

    public void SetExit(string? country, bool connected, string? label, int? latency, string? origin,
                        IReadOnlyList<string> countries)
    {
        if (connected && latency is { } ping) label += $" · {ping} мс";
        if (_country == country && _connected == connected && _label == label && _origin == origin
            && _countries.SequenceEqual(countries)) return;
        _country = country;
        _origin = origin;
        _label = label;
        _countries = countries;
        _connected = connected;
        InvalidateVisual();
    }

    protected override void OnRender(DrawingContext drawing)
    {
        var map = Data.Value;
        var width = Math.Min(RenderSize.Width, RenderSize.Height * map.Aspect);
        if (width <= 0) return;
        var height = width / map.Aspect;
        var left = (RenderSize.Width - width) / 2;
        var top = (RenderSize.Height - height) / 2;
        var radius = width / 180 * 0.37;
        Point Plot(double x, double y) => new(left + x * width, top + y * height);
        Point PlotCountry(MapGeo.Coordinate country)
        {
            var (x, y) = map.Project(country);
            return Plot(x, y);
        }

        var parks = _countries.Where(map.Centers.ContainsKey)
            .ToDictionary(code => code, code => map.Centers[code]);
        _markers = parks.ToDictionary(park => park.Key, park => PlotCountry(park.Value));
        var warm = new[] { 0.30, 0.45, 0.60 }.Select(opacity =>
        {
            var brush = Accent?.Clone();
            if (brush is not null) brush.Opacity = opacity;
            return brush;
        }).ToArray();
        const double warmRadius = 7;
        foreach (var cell in map.Cells)
        {
            var point = Plot(cell.X, cell.Y);
            var latitudeScale = Math.Cos(cell.Coordinate.Latitude * Math.PI / 180);
            var distance = warmRadius * warmRadius;
            foreach (var park in parks.Values)
            {
                var latitude = cell.Coordinate.Latitude - park.Latitude;
                var longitude = (cell.Coordinate.Longitude - park.Longitude) * latitudeScale;
                distance = Math.Min(distance, latitude * latitude + longitude * longitude);
            }
            var warmth = 1 - Math.Sqrt(distance) / warmRadius;
            var brush = warmth <= 0 ? Land : warm[Math.Min(2, (int)(warmth * 3))];
            drawing.DrawEllipse(brush, null, point, radius, radius);
        }
        var ring = new System.Windows.Media.Pen(warm[2], 0.9);
        foreach (var (parkCode, point) in _markers)
        {
            if (parkCode == _country) continue;
            var crowded = _markers.Any(other => other.Key != parkCode && (other.Value - point).LengthSquared < 169);
            if (!crowded) drawing.DrawEllipse(null, ring, point, 3.8, 3.8);
            var markerRadius = crowded ? 2.1 : 1.2;
            drawing.DrawEllipse(Accent, null, point, markerRadius, markerRadius);
        }
        var neutral = (Brush)FindResource("Text");
        Point? home = _origin is { } origin && map.Centers.TryGetValue(origin, out var originCenter)
            ? PlotCountry(originCenter) : null;

        if (_country is { } code && map.Centers.TryGetValue(code, out var center))
        {
            var pin = PlotCountry(center);
            var size = _connected ? 4.5 : 3.5;
            var accent = new System.Windows.Media.Pen(Accent, 1);
            if (_connected && home is { } start && start != pin)
            {
                var route = new StreamGeometry();
                using (var path = route.Open())
                {
                    path.BeginFigure(start, false, false);
                    path.QuadraticBezierTo(new Point((start.X + pin.X) / 2,
                        Math.Min(start.Y, pin.Y) - Math.Min(36, Math.Abs(start.X - pin.X) * 0.22)), pin, true, false);
                }
                drawing.DrawGeometry(null, accent, route);
            }
            if (_connected)
                drawing.DrawEllipse(null, accent, pin, 8, 8);
            drawing.DrawEllipse(Accent, null, pin, size, size);
            if (!string.IsNullOrWhiteSpace(_label))
            {
                var text = new FormattedText(_label, CultureInfo.GetCultureInfo("ru-RU"), System.Windows.FlowDirection.LeftToRight,
                    new Typeface("Segoe UI"), 11, _connected ? Accent ?? neutral : neutral,
                    VisualTreeHelper.GetDpi(this).PixelsPerDip) { MaxTextWidth = 140, MaxLineCount = 1 };
                var labelWidth = text.Width + 14;
                var x = pin.X > RenderSize.Width / 2 ? pin.X - labelWidth - 10 : pin.X + 10;
                x = Math.Clamp(x, 4, Math.Max(4, RenderSize.Width - labelWidth - 4));
                var box = new Rect(x, Math.Max(0, pin.Y - 10), labelWidth, 21);
                drawing.DrawRoundedRectangle((Brush)FindResource("Ground"), accent, box, 10, 10);
                drawing.DrawText(text, new Point(box.Left + 7, box.Top + 2));
            }
        }
        if (home is { } homePoint)
        {
            drawing.DrawEllipse((Brush)FindResource("Ground"), ring, homePoint, 4, 4);
            drawing.DrawEllipse(neutral, null, homePoint, 1.6, 1.6);
            var caption = new FormattedText("Вы", CultureInfo.GetCultureInfo("ru-RU"), System.Windows.FlowDirection.LeftToRight,
                new Typeface("Segoe UI"), 10, (Brush)FindResource("TextDim"), VisualTreeHelper.GetDpi(this).PixelsPerDip);
            drawing.DrawText(caption, new Point(Math.Max(0, homePoint.X - caption.Width - 6), homePoint.Y - 6));
        }
    }

    protected override void OnMouseMove(System.Windows.Input.MouseEventArgs e)
    {
        base.OnMouseMove(e);
        var country = HitCountry(e.GetPosition(this));
        Cursor = country is not null && CanPick ? System.Windows.Input.Cursors.Hand : null;
        if (country == _hoveredCountry) return;
        _hoveredCountry = country;
        ToolTip = country is null ? null : CountryDetails?.Invoke(country) ?? Country.Name(country);
    }

    protected override void OnMouseLeave(System.Windows.Input.MouseEventArgs e)
    {
        base.OnMouseLeave(e);
        _hoveredCountry = null;
        ToolTip = null;
        Cursor = null;
    }

    protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
    {
        base.OnMouseLeftButtonUp(e);
        if (!CanPick || HitCountry(e.GetPosition(this)) is not { } country) return;
        CountryPicked?.Invoke(country);
        e.Handled = true;
    }

    protected override HitTestResult? HitTestCore(PointHitTestParameters hitTestParameters) =>
        new PointHitTestResult(this, hitTestParameters.HitPoint);

    private string? HitCountry(Point point) => _markers
        .Select(marker => (marker.Key, Distance: (marker.Value - point).LengthSquared))
        .Where(marker => marker.Distance <= 144)
        .OrderBy(marker => marker.Distance)
        .Select(marker => marker.Key)
        .FirstOrDefault();

    private static MapGeo Load()
    {
        var uri = new Uri("/Anemia;component/Assets/map.json", UriKind.Relative);
        using var stream = System.Windows.Application.GetResourceStream(uri)!.Stream;
        return MapGeo.Load(stream);
    }
}
