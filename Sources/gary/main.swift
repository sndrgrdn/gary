import Foundation

func stdoutIsDiscarded() -> Bool {
    var out = stat()
    var null = stat()
    guard fstat(STDOUT_FILENO, &out) == 0 else { return true }
    guard stat("/dev/null", &null) == 0 else { return false }
    return out.st_mode & S_IFMT == S_IFCHR && out.st_rdev == null.st_rdev
}

let args = Array(CommandLine.arguments.dropFirst())
if !args.isEmpty, Bundle.main.bundleIdentifier == nil, let invoked = Bundle.main.executablePath,
   let resolved = realpath(invoked, nil).map({ String(cString: $0) }), resolved != invoked, resolved.contains(".app/Contents/MacOS/")
{
    execv(resolved, CommandLine.unsafeArgv)
}

guard let verb = args.first else {
    if Bundle.main.bundleIdentifier != nil {
        if stdoutIsDiscarded() {
            if (try? Paths.log.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 > 5_000_000 {
                try? FileManager.default.removeItem(at: Paths.log)
            }
            for stream in [stdout, stderr] {
                freopen(Paths.log.path, "a", stream)
            }
        }
        exit(runSupervisor())
    }
    fputs("usage: gary <verb> [args] (see gary help) | gary app\n", stderr)
    exit(64)
}

switch verb {
case "app": exit(runApp())
case "login": exit(runLogin(Array(args.dropFirst())))
case "update": exit(runUpdate(Array(args.dropFirst())))
case "doctor": exit(runDoctor())
case "report": exit(runReport())
case grantProbeVerb: exit(runGrantProbe(Array(args.dropFirst())))
case "restore-after": exit(runRestoreAfter(Array(args.dropFirst())))
case "help", "--help", "-h": exit(runHelp())
case "--version": print("gary \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")"); exit(0)
case "plugin": exit(runPlugin(Array(args.dropFirst())))
case "skill": exit(Skill.run(Array(args.dropFirst())))
default: exit(runCli(verb, Array(args.dropFirst())))
}
