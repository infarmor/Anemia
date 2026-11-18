using System.Diagnostics;
using System.IO;
using System.Text.Json;

namespace AnemiaHelper;

internal static class EngineChild
{
    public static Process Start(string binary, string mode, object configuration)
    {
        var process = new Process
        {
            StartInfo = new ProcessStartInfo(binary)
            {
                ArgumentList = { mode },
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            },
        };
        try
        {
            if (!process.Start()) throw new IOException($"Не удалось запустить {mode}");
            var error = process.StandardError.ReadToEndAsync();
            process.StandardInput.WriteLine(JsonSerializer.Serialize(configuration));
            process.StandardInput.Flush();
            var ready = process.StandardOutput.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(12))
                .GetAwaiter().GetResult();
            if (ready != "ready")
                throw new IOException(error.IsCompletedSuccessfully && !string.IsNullOrWhiteSpace(error.Result)
                    ? error.Result.Trim() : $"Движок {mode} не готов");
            _ = process.StandardOutput.ReadToEndAsync();
            return process;
        }
        catch
        {
            Stop(process);
            throw;
        }
    }

    public static void Stop(Process? process)
    {
        if (process is null) return;
        using (process)
        {
            try
            {
                if (process.HasExited) return;
                if (process.StartInfo.RedirectStandardInput)
                {
                    process.StandardInput.Close();
                    if (process.WaitForExit(1200)) return;
                }
                process.Kill(entireProcessTree: true);
                process.WaitForExit(3000);
            }
            catch (InvalidOperationException) { }
            catch (System.ComponentModel.Win32Exception) { }
        }
    }
}
