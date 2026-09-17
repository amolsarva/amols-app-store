import Foundation

/// One concrete thing Backstage can do to fix a broken job.
struct RepairAction: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    /// Candidate replacement paths, when the repair is "point the job at a file that moved".
    var candidates: [String] = []
    var kind: Kind

    enum Kind {
        case load
        case unload
        case restart
        case createLogDirectory(String)
        case replacePath(old: String)
        case installPlist
    }
}

enum Repair {
    /// Find where a missing file went, using Spotlight and a few known folders.
    static func findCandidates(forMissing path: String) -> [String] {
        let name = (path as NSString).lastPathComponent
        var results: [String] = []
        // Interpreters: Spotlight would return hundreds of hits, so offer the sensible ones.
        if name.hasPrefix("python") || name == "node" || name == "ruby" {
            for c in ["/usr/bin/" + name, "/opt/homebrew/bin/" + name, "/usr/local/bin/" + name,
                      "/usr/bin/" + name + "3", "/opt/homebrew/bin/" + name + "3"]
            where FileManager.default.fileExists(atPath: c) { results.append(c) }
            let venvs = Shell.run("/usr/bin/find", [Scanner.documents + "/root", "-maxdepth", "3",
                                                    "-path", "*/bin/" + name], timeout: 8)
            results += venvs.out.split(separator: "\n").map(String.init)
            var seenI = Set<String>()
            return results.filter { seenI.insert($0).inserted && $0 != path }
        }
        let r = Shell.run("/usr/bin/mdfind", ["-name", name], timeout: 8)
        if r.code == 0 {
            results += r.out.split(separator: "\n").map(String.init)
                .filter { (($0 as NSString).lastPathComponent) == name }
        }
        // Spotlight misses some iCloud folders; check the usual suspects directly.
        let extra = [Scanner.documents + "/root", Scanner.documents + "/root/archived",
                     Scanner.documents + "/root/mac-scripts", Scanner.home + "/bin",
                     Scanner.home + "/.local/bin"]
        for dir in extra {
            let p = dir + "/" + name
            if FileManager.default.fileExists(atPath: p) { results.append(p) }
        }
        var seen = Set<String>()
        return Array(results.filter { seen.insert($0).inserted && $0 != path }.prefix(12))
    }

    static func actions(for job: Job) -> [RepairAction] {
        var out: [RepairAction] = []
        guard job.source == .userAgent || job.source == .dormantPlist else { return out }

        for issue in job.issues {
            if issue.text.hasPrefix("The program it launches does not exist: ")
                || issue.text.hasPrefix("A file it needs is missing: ") {
                let missing = String(issue.text.split(separator: ": ", maxSplits: 1).last ?? "")
                let cands = findCandidates(forMissing: missing)
                out.append(RepairAction(
                    title: "Repoint to the moved file",
                    detail: cands.isEmpty
                        ? "Could not find \((missing as NSString).lastPathComponent) anywhere on this Mac. Restore it, or unload the job."
                        : "Rewrite the plist to use the file's current location (the old plist is kept as .bak, then the job is reloaded).",
                    candidates: cands,
                    kind: .replacePath(old: missing)))
            }
            if issue.text.hasPrefix("The \(issue.text.contains("stdout") ? "stdout" : "stderr") log folder does not exist: ") {
                let dir = String(issue.text.split(separator: ": ", maxSplits: 1).last ?? "")
                out.append(RepairAction(title: "Create the log folder",
                                        detail: "mkdir -p \(dir)", kind: .createLogDirectory(dir)))
            }
        }
        if job.source == .userAgent {
            if job.loaded == false {
                out.append(RepairAction(title: "Load into launchd", detail: "launchctl bootstrap gui/\(getuid()) …", kind: .load))
            } else {
                out.append(RepairAction(title: "Restart now", detail: "launchctl kickstart -k — also clears the penalty box.", kind: .restart))
                out.append(RepairAction(title: "Unload (stop running it)", detail: "launchctl bootout — reversible; it loads again at next login unless you remove the plist.", kind: .unload))
            }
        } else if job.source == .dormantPlist {
            out.append(RepairAction(title: "Install into ~/Library/LaunchAgents",
                                    detail: "Copies the plist and loads it. Placeholders like __HOME__ are filled in; a plist with __SCRIPT_PATH__ still needs editing first.",
                                    kind: .installPlist))
        }
        return out
    }

    /// Rewrite every occurrence of `old` with `new` inside a plist, keeping a .bak copy.
    static func rewrite(plistPath: String, old: String, new: String) -> String {
        guard var text = try? String(contentsOfFile: plistPath, encoding: .utf8) else {
            return "Could not read \(plistPath)"
        }
        let backup = plistPath + ".bak-" + String(Int(Date().timeIntervalSince1970))
        try? text.write(toFile: backup, atomically: true, encoding: .utf8)
        text = text.replacingOccurrences(of: old, with: new)
        do {
            try text.write(toFile: plistPath, atomically: true, encoding: .utf8)
        } catch {
            return "Could not write \(plistPath): \(error)"
        }
        return "Updated \(plistPath)\n  \(old)\n→ \(new)\nBackup: \(backup)"
    }

    static func install(plistPath: String) -> String {
        let name = (plistPath as NSString).lastPathComponent
        let dest = Scanner.home + "/Library/LaunchAgents/" + name
        guard var text = try? String(contentsOfFile: plistPath, encoding: .utf8) else { return "Could not read \(plistPath)" }
        text = text.replacingOccurrences(of: "__HOME__", with: Scanner.home)
        if text.contains("__SCRIPT_PATH__") {
            return "This plist still has a __SCRIPT_PATH__ placeholder. Edit it to point at a real script first."
        }
        if FileManager.default.fileExists(atPath: dest) { return "Already installed at \(dest)" }
        do {
            try text.write(toFile: dest, atomically: true, encoding: .utf8)
        } catch {
            return "Could not write \(dest): \(error)"
        }
        let r = Shell.run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", dest], timeout: 15)
        return "Installed \(dest)\nlaunchctl bootstrap exit \(r.code)\n\(r.out)"
    }

    static func createDirectory(_ path: String) -> String {
        let p = (path.replacingOccurrences(of: "__HOME__", with: Scanner.home) as NSString).expandingTildeInPath
        do {
            try FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
            return "Created \(p)"
        } catch {
            return "Could not create \(p): \(error)"
        }
    }
}
