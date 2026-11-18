using System.IO;
using System.Text.Json;

namespace AnemiaCore;

/// <summary>The 2° land grid and country centers shared with macOS and Android.</summary>
public sealed class MapGeo
{
    public readonly record struct Coordinate(double Latitude, double Longitude);
    public readonly record struct Cell(Coordinate Coordinate, double X, double Y);

    private readonly double _latitudeTop;
    private readonly double _latitudeSpan;

    public double Aspect => 360 / _latitudeSpan;
    public IReadOnlyDictionary<string, Coordinate> Centers { get; }
    public IReadOnlyList<Cell> Cells { get; }

    private MapGeo(double latitudeTop, double latitudeBottom, Ring[] rings, Dictionary<string, Coordinate> centers)
    {
        _latitudeTop = latitudeTop;
        _latitudeSpan = latitudeTop - latitudeBottom;
        Centers = centers;

        var cells = new List<Cell>();
        for (var row = 0; row < (int)(_latitudeSpan / 2); row++)
        {
            var latitude = latitudeTop - 1 - row * 2.0;
            for (var column = 0; column < 180; column++)
            {
                var longitude = -179 + column * 2.0 + row % 2;
                if (longitude >= 180) continue;
                var inside = false;
                foreach (var ring in rings)
                    if (ring.Contains(latitude, longitude)) inside = !inside;
                if (!inside) continue;

                var coordinate = new Coordinate(latitude, longitude);
                var (x, y) = Project(coordinate);
                cells.Add(new Cell(coordinate, x, y));
            }
        }
        Cells = cells;
    }

    public (double X, double Y) Project(Coordinate point) =>
        ((point.Longitude + 180) / 360, (_latitudeTop - point.Latitude) / _latitudeSpan);

    public static MapGeo Load(Stream stream)
    {
        using var json = JsonDocument.Parse(stream);
        var map = json.RootElement;
        var rings = map.GetProperty("rings").EnumerateArray()
            .Select(ring => new Ring(ring.EnumerateArray().Select(value => value.GetDouble()).ToArray()))
            .ToArray();
        var centers = map.GetProperty("centers").EnumerateObject().ToDictionary(
            center => center.Name,
            center => new Coordinate(center.Value[0].GetDouble(), center.Value[1].GetDouble()),
            StringComparer.OrdinalIgnoreCase);
        return new MapGeo(map.GetProperty("latTop").GetDouble(), map.GetProperty("latBottom").GetDouble(), rings, centers);
    }

    private sealed class Ring
    {
        private readonly double[] _coordinates;
        private readonly double _minLatitude;
        private readonly double _maxLatitude;
        private readonly double _minLongitude;
        private readonly double _maxLongitude;

        public Ring(double[] coordinates)
        {
            if (coordinates.Length < 6 || coordinates.Length % 2 != 0)
                throw new JsonException("A coastline ring requires at least three longitude/latitude pairs.");
            _coordinates = coordinates;
            _minLatitude = _maxLatitude = coordinates[1];
            _minLongitude = _maxLongitude = coordinates[0];
            for (var i = 2; i < coordinates.Length; i += 2)
            {
                _minLongitude = Math.Min(_minLongitude, coordinates[i]);
                _maxLongitude = Math.Max(_maxLongitude, coordinates[i]);
                _minLatitude = Math.Min(_minLatitude, coordinates[i + 1]);
                _maxLatitude = Math.Max(_maxLatitude, coordinates[i + 1]);
            }
        }

        // Match the Swift ray cast exactly. A geometry hit test can count water as land
        // at this normalized scale, and a hit on an edge must use Swift's strict comparison.
        public bool Contains(double latitude, double longitude)
        {
            if (latitude < _minLatitude || latitude > _maxLatitude ||
                longitude < _minLongitude || longitude > _maxLongitude)
                return false;

            var inside = false;
            var previous = _coordinates.Length - 2;
            for (var current = 0; current < _coordinates.Length; current += 2)
            {
                var currentLatitude = _coordinates[current + 1];
                var previousLatitude = _coordinates[previous + 1];
                if ((currentLatitude > latitude) != (previousLatitude > latitude))
                {
                    var currentLongitude = _coordinates[current];
                    var crossLongitude = (_coordinates[previous] - currentLongitude) *
                        (latitude - currentLatitude) / (previousLatitude - currentLatitude) + currentLongitude;
                    if (longitude < crossLongitude) inside = !inside;
                }
                previous = current;
            }
            return inside;
        }
    }
}
