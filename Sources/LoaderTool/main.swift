import Foundation
import LoaderCore

// Tiny CLI: `LoaderTool emit "<share-link>"` prints the generated Xray config.
// Used for scripting and for validating output against the real engine:
//   LoaderTool emit "vless://…" | xray run -c /dev/stdin -test

func usage() -> Never {
    FileHandle.standardError.write(Data("usage: LoaderTool emit <share-link> [--no-anti]\n".utf8))
    exit(2)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { usage() }

switch cmd {
case "emit":
    guard args.count >= 2 else { usage() }
    let link = args[1]
    var anti: AntiCensorshipOptions = args.contains("--no-anti") ? .off : .recommended
    if let i = args.firstIndex(of: "--profile"), i + 1 < args.count,
       let p = MaskingProfile(rawValue: args[i + 1]) {
        anti = p.options
    }
    do {
        let server = try ShareLinkParser.parse(link)
        print(try XrayConfigBuilder().makeConfigString(server: server, anti: anti))
    } catch let error as LocalizedError where error.errorDescription != nil {
        FileHandle.standardError.write(Data("error: \(error.errorDescription!)\n".utf8))
        exit(1)
    } catch {
        FileHandle.standardError.write(Data("parse error: \(error)\n".utf8))
        exit(1)
    }
default:
    usage()
}
