import Foundation

enum ScriptKind: String, Codable {
    case bash, zsh, python, node, applescript, swift, ruby, other

    static func infer(from path: String) -> ScriptKind {
        switch (path as NSString).pathExtension.lowercased() {
        case "sh", "command", "bash": return .bash
        case "zsh": return .zsh
        case "py": return .python
        case "mjs", "js", "cjs": return .node
        case "applescript", "scpt": return .applescript
        case "swift": return .swift
        case "rb": return .ruby
        default: return .other
        }
    }

    /// How to launch it. nil means "execute directly" (needs +x).
    var interpreter: (String, [String])? {
        switch self {
        case .bash: return ("/bin/bash", [])
        case .zsh: return ("/bin/zsh", [])
        case .python: return ("/usr/bin/env", ["python3"])
        case .node: return ("/usr/bin/env", ["node"])
        case .applescript: return ("/usr/bin/osascript", [])
        case .swift: return ("/usr/bin/env", ["swift"])
        case .ruby: return ("/usr/bin/env", ["ruby"])
        case .other: return nil
        }
    }

    var label: String { rawValue }
}

struct ScriptEntry: Codable, Hashable {
    var path: String
    var name: String = ""
    var whatItDoes: String = ""
    var notes: String = ""
    var defaultArguments: String = ""
    var favorite: Bool = false
    var tracked: Bool = true
}

struct RunRecord: Codable, Hashable, Identifiable {
    var id: String { started.description + path }
    var path: String
    var started: Date
    var finishedSeconds: Double
    var exitCode: Int32
    var logFile: String
    var ok: Bool { exitCode == 0 }
}

struct ScriptItem: Identifiable, Hashable {
    var id: String { path }
    var path: String
    var name: String
    var kind: ScriptKind
    var modified: Date?
    var executable: Bool
    var autoSummary: String
    var entry: ScriptEntry?
    var lastRun: RunRecord?

    var isTracked: Bool { entry?.tracked == true }
    var displayName: String {
        if let n = entry?.name, !n.isEmpty { return n }
        return (path as NSString).lastPathComponent
    }
    var summary: String {
        if let w = entry?.whatItDoes, !w.isEmpty { return w }
        return autoSummary
    }
    var folder: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.replacingOccurrences(of: Scanner.home, with: "~")
    }
}

enum ScriptFinder {
    static let extensions: Set<String> = ["sh", "command", "bash", "zsh", "py", "mjs", "js", "cjs",
                                          "applescript", "scpt", "swift", "rb"]

    static let skipDirs: Set<String> = ["node_modules", ".git", ".venv", "venv", ".build", "dist",
                                        "__pycache__", ".next", "Library", ".vercel", "site-packages",
                                        "cpuguard-env", ".cache", "build", ".wrangler", "vendor"]

    static var defaultRoots: [String] {
        [Scanner.documents + "/root",
         Scanner.documents + "/20 - Tech & Scripts",
         Scanner.home + "/bin",
         Scanner.home + "/.local/bin",
         Scanner.home + "/Library/Scripts",
         Scanner.home + "/Desktop"]
    }

    /// Walk the roots looking for script files. Cheap enough to run on demand; capped for safety.
    static func scan(roots: [String], limit: Int = 4000) -> [String] {
        var found: [String] = []
        let fm = FileManager.default
        for root in roots {
            guard fm.fileExists(atPath: root) else { continue }
            guard let en = fm.enumerator(atPath: root) else { continue }
            while let rel = en.nextObject() as? String {
                if found.count >= limit { break }
                let last = (rel as NSString).lastPathComponent
                if skipDirs.contains(last) || last.hasPrefix(".") && last != ".local" {
                    en.skipDescendants(); continue
                }
                if en.level > 6 { en.skipDescendants(); continue }
                let ext = (rel as NSString).pathExtension.lowercased()
                guard extensions.contains(ext) else { continue }
                found.append(root + "/" + rel)
            }
        }
        return found
    }

    /// First comment block after the shebang, used as an automatic description.
    static func summarize(_ path: String) -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 4000)) ?? Data()
        var lines: [String] = []
        for raw in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).prefix(40) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#!") { continue }
            if line.isEmpty { if lines.isEmpty { continue } else { break } }
            if line.hasPrefix("#") || line.hasPrefix("//") || line.hasPrefix("--") {
                let text = line.drop { $0 == "#" || $0 == "/" || $0 == "-" }.trimmingCharacters(in: .whitespaces)
                if text.isEmpty { continue }
                if text.hasPrefix("!") { continue }
                lines.append(text)
                if lines.count >= 3 { break }
            } else if !lines.isEmpty {
                break
            } else if line.hasPrefix("\"\"\"") {
                continue
            } else {
                break
            }
        }
        return lines.joined(separator: " ")
    }

    static func item(for path: String, entry: ScriptEntry?, lastRun: RunRecord?) -> ScriptItem {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return ScriptItem(path: path,
                          name: (path as NSString).lastPathComponent,
                          kind: ScriptKind.infer(from: path),
                          modified: attrs?[.modificationDate] as? Date,
                          executable: FileManager.default.isExecutableFile(atPath: path),
                          autoSummary: summarize(path),
                          entry: entry,
                          lastRun: lastRun)
    }
}

/// Runs a script and streams its output.
@MainActor
final class ScriptRunner: ObservableObject {
    @Published var output: String = ""
    @Published var running = false
    @Published var finished: RunRecord?

    private var process: Process?

    static var logDirectory: String {
        let d = Scanner.home + "/Library/Logs/Backstage/runs"
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }

    func run(_ item: ScriptItem, arguments: String, onFinish: @escaping (RunRecord) -> Void) {
        guard !running else { return }
        let args = arguments.split(separator: " ").map(String.init)
        let p = Process()
        if let (exe, pre) = item.kind.interpreter {
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = pre + [item.path] + args
        } else if item.executable {
            p.executableURL = URL(fileURLWithPath: item.path)
            p.arguments = args
        } else {
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [item.path] + args
        }
        p.currentDirectoryURL = URL(fileURLWithPath: (item.path as NSString).deletingLastPathComponent)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        p.environment = env

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        output = "$ \(p.executableURL!.path) \((p.arguments ?? []).joined(separator: " "))\n\n"
        running = true
        let started = Date()
        let slug = (item.path as NSString).lastPathComponent.replacingOccurrences(of: " ", with: "_")
        let stamp = ISO8601DateFormatter().string(from: started).replacingOccurrences(of: ":", with: "-")
        let logFile = Self.logDirectory + "/\(stamp)-\(slug).log"

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let chunk = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self.output += chunk }
        }
        p.terminationHandler = { proc in
            Task { @MainActor in
                pipe.fileHandleForReading.readabilityHandler = nil
                self.output += "\n[exit \(proc.terminationStatus)]\n"
                try? self.output.write(toFile: logFile, atomically: true, encoding: .utf8)
                let rec = RunRecord(path: item.path, started: started,
                                    finishedSeconds: Date().timeIntervalSince(started),
                                    exitCode: proc.terminationStatus, logFile: logFile)
                self.running = false
                self.finished = rec
                self.process = nil
                onFinish(rec)
            }
        }
        do {
            try p.run()
            process = p
        } catch {
            output += "Failed to start: \(error)\n"
            running = false
        }
    }

    func stop() {
        process?.terminate()
    }
}
