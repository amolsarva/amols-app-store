import AppKit
import Foundation

@MainActor
final class JobStore: ObservableObject {
    // Background jobs
    @Published var jobs: [Job] = []
    @Published var lastScan: Date? = nil
    @Published var scanning = false
    @Published var showVendor = false
    @Published var notes: [String: JobNote] = [:]
    @Published var lastActionOutput: String = ""
    @Published var pendingSelection: Selection? = nil

    // Scripts
    @Published var scripts: [ScriptItem] = []
    @Published var scriptEntries: [String: ScriptEntry] = [:]
    @Published var runHistory: [RunRecord] = []
    @Published var discovering = false
    @Published var searchRoots: [String] = ScriptFinder.defaultRoots

    // New-Mac setup checklist
    @Published var setupItems: [SetupItem] = []
    @Published var setupStatus: [String: SetupStatus] = [:]
    @Published var setupOutput: String = ""
    @Published var setupBusy: String? = nil

    /// Data files live next to the source (iCloud-synced, editable by AIs), not in app container storage.
    static let dataDirectory = Scanner.documents + "/root/mac-scripts/backstage"
    static var notesPath: String { dataDirectory + "/job-notes.json" }
    static var scriptsPath: String { dataDirectory + "/scripts.json" }
    static var historyPath: String { dataDirectory + "/run-history.json" }

    private var timer: Timer?

    init() {
        loadNotes()
        loadScripts()
        loadSetup()
        refresh()
        rebuildScripts()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    // MARK: jobs

    var visibleJobs: [Job] { jobs.filter { showVendor || !$0.isVendor } }
    var worstHealth: Health { jobs.filter { !$0.isVendor }.map(\.health).max() ?? .ok }
    var problemCount: Int { jobs.filter { !$0.isVendor && $0.health >= .warning }.count }

    func refresh() {
        guard !scanning else { return }
        scanning = true
        Task.detached(priority: .utility) {
            let result = Scanner.scanAll()
            await MainActor.run {
                self.jobs = result
                self.lastScan = Date()
                self.scanning = false
            }
        }
    }

    func description(for job: Job) -> String {
        let n = notes[job.label]?.whatItDoes ?? ""
        return n.isEmpty ? job.summary : n
    }

    func loadNotes() {
        guard let data = FileManager.default.contents(atPath: Self.notesPath),
              let decoded = try? JSONDecoder().decode([String: JobNote].self, from: data) else { return }
        notes = decoded
    }

    func saveNote(_ note: JobNote, for label: String) {
        notes[label] = note
        write(notes, to: Self.notesPath)
    }

    // MARK: scripts

    func loadScripts() {
        if let data = FileManager.default.contents(atPath: Self.scriptsPath),
           let decoded = try? JSONDecoder().decode([String: ScriptEntry].self, from: data) {
            var merged: [String: ScriptEntry] = [:]
            // Entries already using this Mac's home win over entries written on another Mac.
            for (_, entry) in decoded.sorted(by: { !$0.key.hasPrefix(Scanner.home) && $1.key.hasPrefix(Scanner.home) }) {
                var e = entry
                e.path = PortablePath.expand(entry.path)
                merged[e.path] = e
            }
            scriptEntries = merged
        }
        if let data = FileManager.default.contents(atPath: Self.historyPath) {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            if let decoded = (try? dec.decode([RunRecord].self, from: data))
                ?? (try? JSONDecoder().decode([RunRecord].self, from: data)) {
                runHistory = decoded.map { r in var r = r; r.path = PortablePath.expand(r.path); return r }
            }
        }
    }

    private func persistScripts() {
        var out: [String: ScriptEntry] = [:]
        for (_, e) in scriptEntries {
            var e = e
            e.path = PortablePath.portable(e.path)
            out[e.path] = e
        }
        write(out, to: Self.scriptsPath)
    }

    var trackedScripts: [ScriptItem] {
        scripts.filter { $0.isTracked }.sorted {
            if ($0.entry?.favorite ?? false) != ($1.entry?.favorite ?? false) { return $0.entry?.favorite ?? false }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    func lastRun(of path: String) -> RunRecord? {
        runHistory.filter { $0.path == path }.max { $0.started < $1.started }
    }

    func runs(of path: String) -> [RunRecord] {
        runHistory.filter { $0.path == path }.sorted { $0.started > $1.started }
    }

    /// Rebuild the tracked-script list from scripts.json (fast; no disk walk).
    func rebuildScripts() {
        let entries = scriptEntries
        Task.detached(priority: .utility) {
            let items = entries.values
                .filter { FileManager.default.fileExists(atPath: $0.path) }
                .map { e in ScriptFinder.item(for: e.path, entry: e, lastRun: nil) }
            await MainActor.run {
                self.scripts = items.map { i in
                    var i = i; i.lastRun = self.lastRun(of: i.path); return i
                }
            }
        }
    }

    /// Walk the search roots for scripts on this Mac (the "find my scripts" feature).
    func discover(completion: @escaping ([ScriptItem]) -> Void) {
        guard !discovering else { return }
        discovering = true
        let roots = searchRoots
        let entries = scriptEntries
        Task.detached(priority: .utility) {
            let paths = ScriptFinder.scan(roots: roots)
            let items = paths.map { ScriptFinder.item(for: $0, entry: entries[$0], lastRun: nil) }
                .sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
            await MainActor.run {
                self.discovering = false
                completion(items)
            }
        }
    }

    func track(_ item: ScriptItem, on: Bool = true) {
        var e = scriptEntries[item.path] ?? ScriptEntry(path: item.path, name: item.name, whatItDoes: item.autoSummary)
        e.tracked = on
        if on { scriptEntries[item.path] = e } else { scriptEntries.removeValue(forKey: item.path) }
        persistScripts()
        rebuildScripts()
    }

    func saveScript(_ entry: ScriptEntry) {
        scriptEntries[entry.path] = entry
        persistScripts()
        rebuildScripts()
    }

    func record(_ run: RunRecord) {
        runHistory.append(run)
        // keep the last 40 runs per script
        var byPath: [String: [RunRecord]] = [:]
        for r in runHistory { byPath[r.path, default: []].append(r) }
        runHistory = byPath.values.flatMap { $0.sorted { $0.started > $1.started }.prefix(40) }
        write(runHistory.map { r in var r = r; r.path = PortablePath.portable(r.path); return r }, to: Self.historyPath)
        rebuildScripts()
    }

    private func write<T: Encodable>(_ value: T, to path: String) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(atPath: Self.dataDirectory, withIntermediateDirectories: true)
        if let data = try? enc.encode(value) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    // MARK: actions on jobs

    func perform(_ args: [String]) {
        lastActionOutput = "Running: launchctl " + args.joined(separator: " ")
        Task.detached {
            let r = Shell.run("/bin/launchctl", args, timeout: 20)
            await MainActor.run {
                self.lastActionOutput = "launchctl \(args.joined(separator: " "))\nexit \(r.code)\n\(r.out)"
                self.refresh()
            }
        }
    }

    func runNow(_ job: Job) {
        guard let d = job.source.launchctlDomain else { return }
        perform(["kickstart", "-k", "\(d)/\(job.label)"])
    }

    func load(_ job: Job) {
        guard let d = job.source.launchctlDomain, let p = job.plistPath else { return }
        perform(["bootstrap", d, p])
    }

    func unload(_ job: Job) {
        guard let d = job.source.launchctlDomain else { return }
        perform(["bootout", "\(d)/\(job.label)"])
    }

    func applyRepair(_ action: RepairAction, on job: Job, chosenCandidate: String?) {
        switch action.kind {
        case .load: load(job)
        case .unload: unload(job)
        case .restart: runNow(job)
        case .createLogDirectory(let dir):
            lastActionOutput = Repair.createDirectory(dir)
            refresh()
        case .installPlist:
            guard let p = job.plistPath else { return }
            lastActionOutput = Repair.install(plistPath: p)
            refresh()
        case .replacePath(let old):
            guard let plist = job.plistPath, let new = chosenCandidate else {
                lastActionOutput = "Pick the file's new location first."
                return
            }
            var out = Repair.rewrite(plistPath: plist, old: old, new: new)
            if job.source == .userAgent, let d = job.source.launchctlDomain {
                _ = Shell.run("/bin/launchctl", ["bootout", "\(d)/\(job.label)"], timeout: 15)
                let b = Shell.run("/bin/launchctl", ["bootstrap", d, plist], timeout: 15)
                out += "\nReloaded (bootstrap exit \(b.code)) \(b.out)"
            }
            lastActionOutput = out
            refresh()
        }
    }

    // MARK: misc

    func reveal(_ path: String) {
        let p = (path as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: p) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: (p as NSString).deletingLastPathComponent))
        }
    }

    func openFile(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
    }

    func diagnosisReport(_ job: Job) -> String {
        var s = "# Background job diagnosis: \(job.displayName)\n"
        s += "Source: \(job.source.rawValue)\nLabel: \(job.label)\n"
        if let p = job.plistPath { s += "Definition: \(p)\n" }
        s += "Schedule: \(job.schedule)\nStatus: \(job.statusLine)\n"
        if let r = job.runs { s += "Runs since boot: \(r)\n" }
        s += "Command: \(job.program.joined(separator: " "))\n"
        let d = description(for: job)
        if !d.isEmpty { s += "What it does: \(d)\n" }
        s += "\n## Issues\n"
        for i in job.issues { s += "- [\(i.severity.word)] \(i.text)\(i.fix.map { " Fix: \($0)" } ?? "")\n" }
        for log in job.logs {
            s += "\n## \(log.kind) tail (\(log.path))\n```\n\(Scanner.tail(log.path, bytes: 3000))\n```\n"
        }
        s += "\nContext: see ~/Documents/root/AI-README.md for the folder reorganization map.\n"
        return s
    }

    func copy(_ text: String, what: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        lastActionOutput = "Copied \(what) to the clipboard."
    }
}
