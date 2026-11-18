namespace AnemiaCore;

/// <summary>A local installation identifier for panels that count devices.</summary>
public sealed class SubscriptionDeviceIdentity(string? filePath = null)
{
    public string GetOrCreate()
    {
        var path = Path.GetFullPath(filePath ?? DefaultPath());
        try { return Read(path); }
        catch (FileNotFoundException) { }
        catch (DirectoryNotFoundException) { }

        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var id = Guid.NewGuid().ToString("D").ToUpperInvariant();
        var temporaryPath = path + $".{Guid.NewGuid():N}.tmp";
        try
        {
            File.WriteAllText(temporaryPath, id);
            File.Move(temporaryPath, path);
            return id;
        }
        catch (IOException) when (File.Exists(path))
        {
            // A concurrent first use may have installed its ID first.
            return Read(path);
        }
        finally
        {
            File.Delete(temporaryPath);
        }
    }

    private static string Read(string path)
    {
        var saved = File.ReadAllText(path).Trim();
        if (!Guid.TryParseExact(saved, "D", out var id) || id == Guid.Empty)
            throw new IOException("Invalid subscription device ID.");
        return saved;
    }

    private static string DefaultPath()
    {
        var root = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (string.IsNullOrEmpty(root)) throw new IOException("Local application storage unavailable.");
        return Path.Combine(root, "Anemia", "subscription-device-id");
    }
}
