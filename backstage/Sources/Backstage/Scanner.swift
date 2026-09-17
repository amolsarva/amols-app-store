import Foundation

enum Shell {
    @discardableResult
    static func run(_ launchPath: String, _ args: [String], timeout: TimeInterval = 10) -> (code: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        var data = Data()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            return (-2, "timed out after \(Int(timeout))s")
        }
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

enum Scanner {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    static let documents = home + "/Documents"
    static let iCloudDocs = home + "/Library/Mobile Documents/com~apple~CloudDocs/Documents"

    static let vendorPrefixes = ["com.google", "com.microsoft", "com.adobe", "us.zoom", "com.rippling",
                                 "com.openai.atlas", "com.muse", "com.antlogic", "com.clipy", "com.openssh"]

    static func scanAll() -> [Job] {
        var jobs: [Job] = []
        jobs += launchd(dir: home + "/Library/LaunchAgents", source: .userAgent)
        jobs += launchd(dir: "/Library/LaunchAgents", source: .globalAgent)
        jobs += launchd(dir: "/Library/LaunchDaemons", source: .daemon)
        let installed = Set(jobs.map(\.label))
        jobs += dormantPlists(excluding: installed)
        jobs += crontab()
        jobs += openclawCron()
        jobs += claudeScheduled()
        return jobs
    }

    // MARK: launchd

    static func launchd(dir: String, source: JobSource) -> [Job] {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return files.filter { $0.hasSuffix(".plist") }.sorted().compactMap { name in
            parsePlist(path: dir + "/" + name, source: source)
        }.map { job in
            var j = job
            inspectLaunchctl(&j)
            diagnose(&j)
            return j
        }
    }

    static func parsePlist(path: String, source: JobSource) -> Job? {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = obj as? [String: Any] else { return nil }
        let label = dict["Label"] as? String ?? (path as NSString).lastPathComponent
        var job = Job(label: label, displayName: label, source: source, plistPath: path)
        if let args = dict["ProgramArguments"] as? [String] {
            job.program = args
        } else if let prog = dict["Program"] as? String {
            job.program = [prog]
        }
        job.schedule = describeSchedule(dict)
        if let o = dict["StandardOutPath"] as? String { job.logs.append(LogFile(kind: "stdout", path: o)) }
        if let e = dict["StandardErrorPath"] as? String, !job.logs.contains(where: { $0.path == e }) {
            job.logs.append(LogFile(kind: "stderr", path: e))
        }
        job.summary = dict["Comment"] as? String ?? ""
        job.isVendor = source != .userAgent && source != .dormantPlist
            || vendorPrefixes.contains { label.hasPrefix($0) }
        if let xml = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0) {
            job.rawPlist = String(decoding: xml, as: UTF8.self)
        }
        return job
    }

    static func describeSchedule(_ d: [String: Any]) -> String {
        var parts: [String] = []
        if let ka = d["KeepAlive"] {
            if (ka as? Bool) == true || ka is [String: Any] { parts.append("Always on (KeepAlive)") }
        }
        if let s = d["StartInterval"] as? Int { parts.append("Every " + humanInterval(TimeInterval(s))) }
        if let c = d["StartCalendarInterval"] {
            let dicts = (c as? [[String: Any]]) ?? [(c as? [String: Any]) ?? [:]]
            for cd in dicts { parts.append(describeCalendar(cd)) }
        }
        if let w = d["WatchPaths"] as? [String] { parts.append("When files change: " + w.joined(separator: ", ")) }
        if (d["RunAtLoad"] as? Bool) == true { parts.append("at login/load") }
        return parts.isEmpty ? "On demand" : parts.joined(separator: " · ")
    }

    static func describeCalendar(_ c: [String: Any]) -> String {
        let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        let h = c["Hour"] as? Int
        let m = c["Minute"] as? Int ?? 0
        var s = ""
        if let wd = c["Weekday"] as? Int, wd < days.count { s += days[wd] + " " }
        else if let day = c["Day"] as? Int { s += "Day \(day) " }
        else if h != nil { s += "Daily " }
        if let h { s += String(format: "at %02d:%02d", h, m) } else { s += "hourly at :\(String(format: "%02d", m))" }
        return s
    }

    static func humanInterval(_ t: TimeInterval) -> String {
        if t >= 86400, t.truncatingRemainder(dividingBy: 86400) == 0 { return "\(Int(t / 86400))d" }
        if t >= 3600, t.truncatingRemainder(dividingBy: 3600) == 0 { return "\(Int(t / 3600))h" }
        if t >= 60 { return "\(Int(t / 60))m" }
        return "\(Int(t))s"
    }

    static func inspectLaunchctl(_ job: inout Job) {
        guard let domain = job.source.launchctlDomain else { return }
        let r = Shell.run("/bin/launchctl", ["print", "\(domain)/\(job.label)"], timeout: 5)
        if r.code != 0 {
            job.loaded = false
            return
        }
        job.loaded = true
        func first(_ key: String) -> String? {
            for line in r.out.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix(key + " = ") { return String(t.dropFirst(key.count + 3)) }
            }
            return nil
        }
        if let st = first("state") { job.running = st == "running" }
        if let p = first("pid"), let n = Int(p) { job.pid = n }
        job.lastExit = first("last exit code")
        if let rn = first("runs"), let n = Int(rn) { job.runs = n }
        if let props = first("properties"), props.contains("penalty box") {
            job.issues.append(Issue(severity: .warning,
                                    text: "launchd has put this job in the penalty box (it keeps crashing on start, so launchd is throttling restarts).",
                                    fix: "Fix the underlying error shown in the logs, then use Restart."))
        }
    }

    // MARK: Diagnosis

    static func pathExists(_ p: String) -> Bool {
        // Template plists in project folders use __HOME__ as a placeholder.
        let expanded = (p.replacingOccurrences(of: "__HOME__", with: home) as NSString).expandingTildeInPath
        return FileManager.default.fileExists(atPath: expanded)
    }

    static func looksLikePath(_ s: String) -> Bool {
        (s.hasPrefix("/") || s.hasPrefix("~/")) && !s.contains(" -") && !s.hasPrefix("/dev/")
    }

    static func diagnose(_ job: inout Job) {
        if let exe = job.program.first, looksLikePath(exe), !pathExists(exe) {
            job.issues.append(Issue(severity: .broken, text: "The program it launches does not exist: \(exe)",
                                    fix: "Point ProgramArguments at the new location, or reinstall the tool."))
        }
        for arg in job.program.dropFirst() where looksLikePath(arg) && !pathExists(arg) {
            job.issues.append(Issue(severity: .broken, text: "A file it needs is missing: \(arg)",
                                    fix: "The script was probably moved or deleted. Search for it (e.g. `mdfind -name \((arg as NSString).lastPathComponent)`) and update the plist."))
        }
        if job.source.isLaunchd {
            if job.loaded == false {
                job.issues.append(Issue(severity: job.isVendor ? .info : .warning,
                                        text: "Installed on disk but not loaded in launchd, so it never runs.",
                                        fix: job.source == .userAgent ? "Use Load, or run: launchctl bootstrap gui/\(getuid()) \"\(job.plistPath ?? "")\"" : nil))
            }
            if let e = job.lastExit, !e.hasPrefix("0"), !e.contains("never exited") {
                let alwaysOn = job.schedule.contains("KeepAlive")
                job.issues.append(Issue(severity: alwaysOn && !job.running ? .broken : .warning,
                                        text: "Last run exited with code \(e).",
                                        fix: "Check the stderr log below for the error message."))
            }
        }
        for log in job.logs {
            let dir = (log.path as NSString).deletingLastPathComponent
            if !pathExists(dir) {
                job.issues.append(Issue(severity: .warning, text: "The \(log.kind) log folder does not exist: \(dir)",
                                        fix: "launchd cannot write logs there; the job may silently fail to start."))
            }
            if log.path.hasPrefix("/tmp/") || log.path.hasPrefix("/private/tmp/") {
                job.issues.append(Issue(severity: .info, text: "\(log.kind) goes to /tmp, which is wiped on reboot."))
            }
        }
        let allPaths = job.program + job.logs.map(\.path)
        if allPaths.contains(where: { $0.contains("Mobile Documents") || $0.hasPrefix(documents) }) {
            job.issues.append(Issue(severity: .info,
                                    text: "Uses a path inside iCloud Documents. If that folder is reorganized, or files get evicted, this job can break.",
                                    fix: "See ~/Documents/root/AI-README.md for the reorg map."))
        }
        job.lastActivity = job.logs.compactMap { modDate($0.path) }.max()
        if job.logs.isEmpty && job.source.isLaunchd && !job.isVendor {
            job.issues.append(Issue(severity: .info, text: "No log files configured, so there is no record of what it did.",
                                    fix: "Add StandardOutPath / StandardErrorPath to the plist."))
        }
    }

    static func modDate(_ p: String) -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: (p as NSString).expandingTildeInPath)
        return attrs?[.modificationDate] as? Date
    }

    // MARK: Other sources

    /// Plists that look like launch agents but live in project folders and are not installed.
    static func dormantPlists(excluding installed: Set<String>) -> [Job] {
        let roots = [documents + "/root/mac-scripts", documents + "/20 - Tech & Scripts",
                     documents + "/Claude/Work outputs claude", documents + "/root/mac-scripts/backstage"]
        var out: [Job] = []
        for root in roots {
            guard let e = FileManager.default.enumerator(atPath: root) else { continue }
            while let rel = e.nextObject() as? String {
                if rel.contains("node_modules") || rel.contains(".git/") { e.skipDescendants(); continue }
                if e.level > 3 { e.skipDescendants(); continue }
                guard rel.hasSuffix(".plist") else { continue }
                let path = root + "/" + rel
                guard var job = parsePlist(path: path, source: .dormantPlist), !job.program.isEmpty,
                      !installed.contains(job.label) else { continue }
                job.isVendor = false
                job.issues.append(Issue(severity: .info, text: "Found in a project folder but not installed in ~/Library/LaunchAgents, so it is not running.",
                                        fix: "If you want it: cp the plist to ~/Library/LaunchAgents and Load it."))
                diagnose(&job)
                job.issues.removeAll { $0.text.hasPrefix("Installed on disk") }
                out.append(job)
            }
        }
        return out
    }

    static func crontab() -> [Job] {
        let r = Shell.run("/usr/bin/crontab", ["-l"], timeout: 5)
        guard r.code == 0 else { return [] }
        return r.out.split(separator: "\n").map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") }
            .enumerated().map { i, line in
                let fields = line.split(separator: " ", maxSplits: 5).map(String.init)
                var job = Job(label: "cron-\(i + 1)", displayName: fields.last ?? line, source: .crontab)
                job.schedule = fields.prefix(5).joined(separator: " ")
                job.program = [fields.last ?? line]
                job.rawPlist = line
                return job
            }
    }

    static func openclawCron() -> [Job] {
        let path = home + "/.openclaw/cron/jobs.json"
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["jobs"] as? [[String: Any]] else { return [] }
        return list.map { j in
            let id = j["id"] as? String ?? UUID().uuidString
            var job = Job(label: id, displayName: j["name"] as? String ?? id, source: .openclaw, plistPath: path)
            job.summary = j["description"] as? String ?? ""
            if let s = j["schedule"] as? [String: Any] {
                if let every = s["everyMs"] as? Double { job.schedule = "Every " + humanInterval(every / 1000) }
                else if let expr = s["expr"] as? String { job.schedule = "cron " + expr }
                else { job.schedule = s["kind"] as? String ?? "—" }
            }
            if (j["enabled"] as? Bool) == false {
                job.issues.append(Issue(severity: .info, text: "Disabled in OpenClaw."))
            }
            if let p = j["payload"] as? [String: Any], let msg = p["message"] as? String {
                job.program = [msg]
            }
            let runLog = home + "/.openclaw/cron/runs/\(id).jsonl"
            if FileManager.default.fileExists(atPath: runLog) { job.logs = [LogFile(kind: "runs", path: runLog)] }
            job.lastActivity = modDate(runLog)
            job.issues.append(Issue(severity: .info, text: "Runs inside the OpenClaw gateway (ai.openclaw.gateway). If the gateway is not running, this job does not run either."))
            if let data = try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted]) {
                job.rawPlist = String(decoding: data, as: UTF8.self)
            }
            return job
        }
    }

    static func claudeScheduled() -> [Job] {
        let dir = documents + "/Claude/Scheduled"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return names.sorted().compactMap { name in
            let path = dir + "/" + name + "/SKILL.md"
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
            var job = Job(label: name, displayName: name, source: .claudeScheduled, plistPath: path)
            for line in text.split(separator: "\n").prefix(8) where line.hasPrefix("description:") {
                job.summary = line.dropFirst("description:".count).trimmingCharacters(in: .whitespaces)
            }
            job.schedule = "Managed in the Claude desktop app (Scheduled)"
            job.program = ["Claude prompt: " + path]
            job.lastActivity = modDate(path)
            job.rawPlist = text
            job.issues.append(Issue(severity: .info, text: "Runs inside the Claude desktop app, only while it is open. Run history is in the Claude app, not on disk."))
            return job
        }
    }

    // MARK: Logs

    static func tail(_ path: String, bytes: Int = 12_000) -> String {
        let p = (path as NSString).expandingTildeInPath
        guard let h = FileHandle(forReadingAtPath: p) else { return "(log file does not exist yet: \(p))" }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? h.seek(toOffset: start)
        let data = (try? h.readToEnd()) ?? Data()
        let s = String(decoding: data, as: UTF8.self)
        return s.isEmpty ? "(empty log)" : s
    }
}
