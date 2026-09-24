// iMessage Sync helper.
//
// macOS only lets a program read ~/Library/Messages if *it* has Full Disk Access.
// A launchd job running python directly would need FDA granted to python itself
// (a moving target across upgrades). Instead the job starts this tiny app, the user
// grants FDA to "iMessage Sync.app" once, and every child it spawns inherits it.
//
// Usage: iMessageSync <program> [args...]   (it runs the program and returns its exit code)
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
guard let program = args.first else {
    FileHandle.standardError.write("usage: iMessageSync <program> [args...]\n".data(using: .utf8)!)
    exit(64)
}

let child = Process()
child.executableURL = URL(fileURLWithPath: program)
child.arguments = Array(args.dropFirst())

// Forward launchd's stop signal so an unload doesn't orphan a long media encode.
signal(SIGTERM, SIG_IGN)
let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
term.setEventHandler { child.terminate() }
term.resume()

do {
    try child.run()
} catch {
    FileHandle.standardError.write("iMessageSync: cannot start \(program): \(error)\n".data(using: .utf8)!)
    exit(127)
}
DispatchQueue.global().async {
    child.waitUntilExit()
    exit(child.terminationStatus)
}
dispatchMain()
