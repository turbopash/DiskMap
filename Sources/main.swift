import AppKit

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "--selftest": exit(runSelfTest())
case "--snapshot": exit(runSnapshot(Array(args.dropFirst())))
case "--uitest": uiTestArgs = Array(args.dropFirst()); runApp()
case "--flowtest": uiTestArgs = ["flow"]; runApp()
case "--make-icon": exit(makeIcon(args[1]))
default: runApp()
}
