using AnemiaCore;
using System.IO;

// AnemiaTool — the C# counterpart of Sources/LoaderTool: a CLI over AnemiaCore
// that lets the Windows port be checked the way macOS and Android are. Not
// "the unit tests pass", but "the engine accepted what the port emitted".
//
//   AnemiaTool emit <share-link>        — the Xray config for one server
//   AnemiaTool hysteria-yaml <link> [--socks-port N] — the hysteria client YAML, on stdout
//   AnemiaTool traffic <in.json> <out.json> — read a traffic document and write it
//       back, so `LoaderTool ledger-read` can prove the bytes this port writes are
//       the bytes macOS and iOS read without loss
//
// A link the port cannot handle prints `error\t<link>\t<reason>` and exits 3, so
// a caller sees which case failed instead of a stack trace half-way through a
// run — and, in the verification loop, cannot mistake "the parser refused" for
// "the engine refused".

if (args.Length >= 2 && args[0] == "sync")
{
    // Write both bundle forms for every case in a directory, so the real Swift
    // decoder (`LoaderTool sync-read`) can read what this port produced — the
    // file form byte for byte and the QR link through Apple's own inflater.
    if (args.Length < 3) { Console.Error.WriteLine("usage: AnemiaTool sync <cases-dir> <out-dir>"); return 2; }
    Directory.CreateDirectory(args[2]);
    var written = 0;
    foreach (var file in Directory.GetFiles(args[1], "*.json").OrderBy(n => n, StringComparer.Ordinal))
    {
        var name = Path.GetFileNameWithoutExtension(file);
        var caseNode = System.Text.Json.Nodes.JsonNode.Parse(File.ReadAllText(file));
        var kind = caseNode?["kind"]?.GetValue<string>();
        var bundle = SyncBundle.FromJson(caseNode?["bundle"]);
        if (bundle is null || kind is null) { Console.WriteLine($"{name}\terror\tcase"); continue; }
        try
        {
            if (kind == "file")
            {
                var path = Path.Combine(args[2], name + "." + SyncBundle.FileExtension);
                File.WriteAllText(path, bundle.FileText());
                Console.WriteLine($"{name}\tfile\t{path}");
                written++;
            }
            else if (kind == "link")
            {
                var path = Path.Combine(args[2], name + ".link.txt");
                File.WriteAllText(path, bundle.Link());
                Console.WriteLine($"{name}\tlink\t{path}");
                written++;
            }
        }
        catch (Exception e) { Console.WriteLine($"{name}\terror\t{e.GetType().Name}"); }
    }
    Console.Error.WriteLine($"AnemiaTool sync: файлов бандла написано {written}");
    return 0;
}

if (args.Length >= 2 && args[0] == "state")
{
    // Decode a state.json with the app's own lenient reader and write it back:
    // the same contour `traffic` gives for the ledger, so the shared golden can
    // be compared against what this port *stores*, not what it echoes.
    if (args.Length < 3) { Console.Error.WriteLine("usage: AnemiaTool state <in.json> <out.json>"); return 2; }
    try
    {
        System.Text.Json.Nodes.JsonNode? parsed;
        try { parsed = System.Text.Json.Nodes.JsonNode.Parse(File.ReadAllText(args[1])); }
        catch (System.Text.Json.JsonException) { parsed = null; }   // a truncated file is "not a state", not a crash
        var read = AnemiaCore.PersistedState.FromJson(parsed);
        if (read is null) { Console.Error.WriteLine("state: unreadable document " + args[1]); return 3; }
        File.WriteAllText(args[2], read.ToJson().ToJsonString(new System.Text.Json.JsonSerializerOptions
        {
            Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
            // The same resolver this runtime needs before it will serialise a
            // JsonNode built from plain values at all.
            TypeInfoResolver = new System.Text.Json.Serialization.Metadata.DefaultJsonTypeInfoResolver(),
        }));
        return 0;
    }
    catch (Exception e)
    {
        Console.Error.WriteLine($"state: {e.GetType().Name}: {e.Message}");
        return 4;
    }
}

// `traffic` works on a ledger document, not a share link, so it branches before
// the link parsing below — and it fails loudly rather than writing a file the
// Swift reader would then call "an empty ledger".
if (args.Length >= 2 && args[0] == "traffic")
{
    if (args.Length < 3)
    {
        Console.Error.WriteLine("usage: AnemiaTool traffic <in.json> <out.json>");
        return 2;
    }
    try
    {
        var read = TrafficLedger.FromJson(File.ReadAllText(args[1]));
        if (read is null)
        {
            Console.Error.WriteLine($"traffic: unreadable document {args[1]}");
            return 3;
        }
        File.WriteAllText(args[2], read.ToJson());
        return 0;
    }
    catch (Exception e)
    {
        // A missing or unwritable file must come back as a nonzero exit and a
        // line, not a stack trace the harness would read as "the port crashes".
        Console.Error.WriteLine($"traffic: {e.GetType().Name}: {e.Message}");
        return 4;
    }
}

if (args.Length < 2)
{
    Console.Error.WriteLine("usage: AnemiaTool <emit|hysteria-yaml|traffic> …");
    return 2;
}

var verb = args[0];
var link = args[1];
var socksPort = 21180;
for (var i = 2; i < args.Length - 1; i++)
    if (args[i] == "--socks-port" && int.TryParse(args[i + 1], out var parsed)) socksPort = parsed;

try
{
    // `server <json>` rows of the shared fixture describe a server a link cannot
    // (an IPv6 address without brackets, hopping that does not cover the port),
    // so the tool has to accept them the same way LoaderTool does.
    var server = link.Length > 0 && link[0] == 0x7B
        ? AnemiaCore.PersistedState.ProxyServerFromJson(System.Text.Json.Nodes.JsonNode.Parse(link))
            ?? throw new AnemiaCore.ParseErrorException(AnemiaCore.ParseErrorKind.InvalidBase64, "bad server json")
        : ShareLinkParser.Parse(link);
    if (verb == "hysteria-yaml")
    {
        foreach (var problem in HysteriaConfigBuilder.Validate(server))
            Console.Error.WriteLine("problem: " + problem);
        Console.Write(HysteriaConfigBuilder.MakeClientConfig(server, socksPort));
        return 0;
    }
    Console.Write(new XrayConfigBuilder().MakeConfigString(server));
    return 0;
}
catch (ParseErrorException e)
{
    // A scheme this port does not implement yet is not a bug: the corpus is
    // shared with the other ports, and conflating the two would hide real
    // failures inside a pile of expected ones.
    var kind = e.Kind == ParseErrorKind.UnsupportedScheme ? "unsupported-scheme" : "parse";
    Console.WriteLine($"error\t{link}\t{kind}\t{e.Message}");
    return 3;
}
catch (ConfigBuilderException e)
{
    Console.WriteLine($"error\t{link}\tconfig\t{e.Message}");
    return 3;
}
catch (Exception e)
{
    // Anything else is a bug, and it must still come back as a line the harness
    // can name: an unhandled exception here produced an empty config file and
    // the engine then reported "failed to decode JSON" about someone else's
    // input.
    Console.WriteLine($"error\t{link}\tcrash\t{e.GetType().Name}: {e.Message}");
    return 4;
}
