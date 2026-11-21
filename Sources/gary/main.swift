import Foundation

let logURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/gary.log")

func stdoutIsDiscarded() -> Bool {
    var out = stat(), null = stat()
    guard fstat(STDOUT_FILENO, &out) == 0 else { return true }
    guard stat("/dev/null", &null) == 0 else { return false }
    return out.st_mode & S_IFMT == S_IFCHR && out.st_rdev == null.st_rdev
}

let args = Array(CommandLine.arguments.dropFirst())
guard let verb = args.first else {
    if Bundle.main.bundleIdentifier != nil {
        if stdoutIsDiscarded() {
            if (try? logURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 > 5_000_000 {
                try? FileManager.default.removeItem(at: logURL)
            }
            for stream in [stdout, stderr] { freopen(logURL.path, "a", stream) }
        }
        exit(runApp())
    }
    fputs("usage: gary <verb> [args] (see gary help) | gary app\n", stderr)
    exit(64)
}

switch verb {
case "app": exit(runApp())
case "help", "--help", "-h": exit(runHelp())
case "plugin": exit(runPlugin(Array(args.dropFirst())))
default: exit(runCli(verb, Array(args.dropFirst())))
}
