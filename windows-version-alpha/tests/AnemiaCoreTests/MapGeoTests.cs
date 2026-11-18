using AnemiaCore;
using Xunit;

namespace AnemiaCoreTests;

public sealed class MapGeoTests
{
    [Fact]
    public void LandGridMatchesSwiftExactly()
    {
        var assembly = typeof(MapGeoTests).Assembly;
        using var geometry = assembly.GetManifestResourceStream("Anemia.Map.Geometry")!;
        using var reader = new StreamReader(assembly.GetManifestResourceStream("Anemia.Map.SwiftDots")!);
        var map = MapGeo.Load(geometry);
        var expected = reader.ReadToEnd().Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        var actual = map.Cells.Select(cell => $"dot\t{Hex(cell.Coordinate.Latitude)}\t" +
            $"{Hex(cell.Coordinate.Longitude)}\t{Hex(cell.X)}\t{Hex(cell.Y)}").ToArray();

        Assert.Equal(expected, actual);
    }

    private static string Hex(double value) => BitConverter.DoubleToUInt64Bits(value).ToString("x16");
}
