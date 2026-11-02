import Foundation
import InboxCore

// inboxctl: command-line and MCP access to the Unified Inbox database. See `inboxctl help`.
let argv = Array(CommandLine.arguments.dropFirst())
let args = CLIArguments(argv)
let path = args.options["db"].map { ($0 as NSString).expandingTildeInPath } ?? InboxStore.defaultPath()

guard FileManager.default.fileExists(atPath: path) else {
    FileHandle.standardError.write(Data("No inbox database at \(path). Open Unified Inbox once first, or pass --db <path>.\n".utf8))
    exit(66)
}

let store: InboxStore
do {
    store = try InboxStore(path: path)
} catch {
    FileHandle.standardError.write(Data("Couldn't open \(path): \(error.localizedDescription)\n".utf8))
    exit(74)
}

if args.command == "mcp" {
    InboxMCPServer(store: store, allowWrites: args.flags.contains("allow-writes")).runStdio()
    exit(0)
}

let result = InboxCLI.run(args, store: store)
let out = result.output.hasSuffix("\n") ? result.output : result.output + "\n"
if result.exitCode == 0 {
    FileHandle.standardOutput.write(Data(out.utf8))
} else {
    FileHandle.standardError.write(Data(out.utf8))
}
exit(result.exitCode)
