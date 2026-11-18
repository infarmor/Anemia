using System.Windows;
using System.Windows.Media;
using Brush = System.Windows.Media.Brush;
using Point = System.Windows.Point;

namespace AnemiaApp;

public sealed class TrafficSparkline : FrameworkElement
{
    private readonly Queue<(long Down, long Up)> _samples = new();

    public void Add(long down, long up)
    {
        if (_samples.Count == 36) _samples.Dequeue();
        _samples.Enqueue((down, up));
        InvalidateVisual();
    }

    public void Clear()
    {
        if (_samples.Count == 0) return;
        _samples.Clear();
        InvalidateVisual();
    }

    protected override void OnRender(DrawingContext drawing)
    {
        var baseline = RenderSize.Height - 1;
        var neutral = (Brush)FindResource("TextDim");
        drawing.DrawLine(new System.Windows.Media.Pen(neutral, 0.5), new Point(0, baseline),
            new Point(RenderSize.Width, baseline));
        if (_samples.Count < 2) return;

        var samples = _samples.ToArray();
        var scale = Math.Max(1d, samples.Max(sample => Math.Max(sample.Up, sample.Down)));
        var step = RenderSize.Width / (samples.Length - 1);
        Draw(samples.Select(sample => sample.Down), (Brush)FindResource("Accent"), true);
        Draw(samples.Select(sample => sample.Up), neutral, false);

        void Draw(IEnumerable<long> values, Brush brush, bool shade)
        {
            var points = values.Select((value, index) =>
                new Point(index * step, baseline - value / scale * (baseline - 3))).ToArray();
            var line = new StreamGeometry();
            using (var path = line.Open())
            {
                path.BeginFigure(points[0], shade, shade);
                for (var i = 1; i < points.Length; i++)
                {
                    var previous = points[i - 1];
                    var next = points[i];
                    var middle = (previous.X + next.X) / 2;
                    path.BezierTo(new Point(middle, previous.Y), new Point(middle, next.Y), next, true, false);
                }
                if (shade)
                {
                    path.LineTo(new Point(points[^1].X, baseline), false, false);
                    path.LineTo(new Point(points[0].X, baseline), false, false);
                }
            }
            var fill = shade ? brush.Clone() : null;
            if (fill is not null) fill.Opacity = 0.15;
            drawing.DrawGeometry(fill, new System.Windows.Media.Pen(brush, shade ? 1.2 : 0.8), line);
        }
    }
}
