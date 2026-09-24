import SwiftUI
import AppKit

struct HealthDot: View {
    let health: Health
    var body: some View { Image(systemName: health.symbol).foregroundStyle(health.color) }
}

func relative(_ d: Date?) -> String {
    guard let d else { return "never" }
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    return f.localizedString(for: d, relativeTo: Date())
}

enum Selection: Hashable {
    case overview
    case setup
    case discover
    case script(String)
    case job(String)
}

// MARK: - Dashboard

struct DashboardView: View {
    @EnvironmentObject var store: JobStore
    @State private var selection: Selection? = UserDefaults.standard.bool(forKey: "setupSeen") ? .overview : .setup
    @State private var search = ""

    var filteredJobs: [Job] {
        store.visibleJobs.filter {
            search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search)
                || $0.program.joined(separator: " ").localizedCaseInsensitiveContains(search)
        }
    }

    var filteredScripts: [ScriptItem] {
        store.trackedScripts.filter {
            search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search)
                || $0.path.localizedCaseInsensitiveContains(search)
                || $0.summary.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Overview", systemImage: "square.grid.2x2").tag(Selection.overview)
                Label(store.missingRequiredCount > 0 ? "New Mac setup (\(store.missingRequiredCount) to do)" : "New Mac setup",
                      systemImage: "checklist").tag(Selection.setup)
                Label("Find scripts on this Mac", systemImage: "magnifyingglass").tag(Selection.discover)

                Section("My scripts") {
                    if filteredScripts.isEmpty {
                        Text("None yet — use “Find scripts on this Mac”.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(filteredScripts) { s in
                        ScriptRow(item: s).tag(Selection.script(s.path))
                    }
                }

                ForEach(JobSource.allCases, id: \.self) { source in
                    let items = filteredJobs.filter { $0.source == source }
                    if !items.isEmpty {
                        Section(source.rawValue) {
                            ForEach(items) { job in JobRow(job: job).tag(Selection.job(job.id)) }
                        }
                    }
                }
            }
            .searchable(text: $search, placement: .sidebar)
            .navigationSplitViewColumnWidth(min: 280, ideal: 330)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Show vendor & system jobs", isOn: $store.showVendor)
                    Text(store.scanning ? "Scanning…" : "Jobs scanned \(relative(store.lastScan))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(10)
            }
        } detail: {
            switch selection {
            case .setup: SetupView(select: { selection = $0 })
            case .discover: DiscoverView()
            case .script(let path):
                if let item = store.scripts.first(where: { $0.path == path }) {
                    ScriptDetailView(item: item).id(path)
                } else { ContentUnavailableView("Script not found", systemImage: "questionmark.folder") }
            case .job(let id):
                if let job = store.jobs.first(where: { $0.id == id }) {
                    JobDetailView(job: job).id(id)
                } else { ContentUnavailableView("Job not found", systemImage: "questionmark.folder") }
            default: OverviewView(select: { selection = $0 })
            }
        }
        .toolbar {
            ToolbarItem { Button { store.refresh(); store.rebuildScripts() } label: { Label("Refresh", systemImage: "arrow.clockwise") } }
        }
        .frame(minWidth: 940, minHeight: 600)
        .onReceive(store.$pendingSelection.compactMap { $0 }) { sel in
            selection = sel
            store.pendingSelection = nil
        }
    }
}

struct ScriptRow: View {
    let item: ScriptItem
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: item.entry?.favorite == true ? "star.fill" : "terminal")
                .foregroundStyle(item.entry?.favorite == true ? Color.yellow : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName).lineLimit(1)
                Text(item.summary.isEmpty ? item.folder : item.summary)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let r = item.lastRun {
                    Text("last run \(relative(r.started)) · \(r.ok ? "ok" : "exit \(r.exitCode)")")
                        .font(.caption2).foregroundStyle(r.ok ? Color.secondary : Color.red)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct JobRow: View {
    let job: Job
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            HealthDot(health: job.health)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.displayName).lineLimit(1)
                Text(job.schedule).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text("\(job.statusLine) · \(relative(job.lastActivity))")
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Overview

struct OverviewView: View {
    @EnvironmentObject var store: JobStore
    let select: (Selection) -> Void

    var body: some View {
        let mine = store.jobs.filter { !$0.isVendor }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Command center").font(.largeTitle.bold())
                if store.missingRequiredCount > 0 {
                    Button { select(.setup) } label: {
                        HStack {
                            Image(systemName: "checklist").foregroundStyle(.orange)
                            Text("\(store.missingRequiredCount) setup item\(store.missingRequiredCount == 1 ? "" : "s") missing on this Mac. Open New Mac setup.")
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                }
                HStack(spacing: 12) {
                    StatTile(title: "Scripts", value: "\(store.trackedScripts.count)", color: .primary)
                    StatTile(title: "Background jobs", value: "\(mine.count)", color: .primary)
                    StatTile(title: "Broken", value: "\(mine.filter { $0.health == .broken }.count)", color: .red)
                    StatTile(title: "Need attention", value: "\(mine.filter { $0.health == .warning }.count)", color: .orange)
                }

                if !store.trackedScripts.isEmpty {
                    Text("Scripts").font(.headline)
                    ForEach(store.trackedScripts.prefix(12)) { s in
                        Button { select(.script(s.path)) } label: {
                            OverviewScriptRow(item: s)
                        }.buttonStyle(.plain)
                        Divider()
                    }
                }

                Text("Background jobs, problems first").font(.headline).padding(.top, 8)
                ForEach(mine.sorted { $0.health > $1.health }) { job in
                    Button { select(.job(job.id)) } label: {
                        HStack(alignment: .top) {
                            HealthDot(health: job.health)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(job.displayName).font(.body.weight(.medium))
                                Text(job.issues.sorted { $0.severity > $1.severity }.first?.text
                                     ?? (store.description(for: job).isEmpty ? job.schedule : store.description(for: job)))
                                    .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            Text(relative(job.lastActivity)).font(.caption).foregroundStyle(.secondary)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Divider()
                }
            }
            .padding(24)
        }
    }
}

struct StatTile: View {
    let title: String
    let value: String
    let color: Color
    var body: some View {
        VStack(alignment: .leading) {
            Text(value).font(.system(size: 28, weight: .semibold, design: .rounded)).foregroundStyle(color)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

func sectionBox<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
    VStack(alignment: .leading, spacing: 8) {
        Text(title).font(.headline)
        content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
}

// MARK: - Scripts

struct ScriptDetailView: View {
    @EnvironmentObject var store: JobStore
    @StateObject private var runner = ScriptRunner()
    let item: ScriptItem
    @State private var entry = ScriptEntry(path: "")
    @State private var args = ""
    @State private var pendingRun: PendingRun?

    struct PendingRun: Identifiable {
        let id = UUID()
        let label: String
        let args: String
    }

    func start(_ label: String, _ arguments: String) {
        runner.run(item, arguments: arguments) { rec in store.record(rec) }
    }

    func launch() {
        if let app = entry.launchApp, !app.isEmpty {
            let path = PortablePath.expand((app as NSString).expandingTildeInPath)
            if FileManager.default.fileExists(atPath: path) {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
                return
            }
        }
        start("Launch", entry.launchArgs ?? args)
    }

    var actionsBox: some View {
        let legacy = !entry.hasModes
        let canLaunch = legacy || entry.launchArgs != nil || entry.launchApp != nil
        let canInstall = entry.installArgs != nil
        let canRepair = entry.repairArgs != nil
        return sectionBox("Actions") {
            HStack(alignment: .top, spacing: 12) {
                actionButton("Launch", symbol: "play.fill",
                             detail: legacy ? "Run this tool now." : "Open or run the tool now.",
                             enabled: canLaunch && !runner.running) { launch() }
                actionButton("Install", symbol: "arrow.down.circle.fill",
                             detail: "Set it up on this Mac: background job, hooks, helper files.",
                             enabled: canInstall && !runner.running) {
                    pendingRun = PendingRun(label: "Install", args: entry.installArgs ?? "")
                }
                actionButton("Repair", symbol: "wrench.and.screwdriver.fill",
                             detail: "Fix it if it is broken. Safe to run again.",
                             enabled: canRepair && !runner.running) {
                    pendingRun = PendingRun(label: "Repair", args: entry.repairArgs ?? "")
                }
            }
            if !legacy && (!canInstall || !canRepair || !canLaunch) {
                Text("Greyed-out actions aren't set up for this tool. Turn them on under “Set up the buttons” below.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if runner.running {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Running…").foregroundStyle(.secondary)
                    Button("Stop", role: .destructive) { runner.stop() }
                }
            }
            outputPanel
        }
    }

    func actionButton(_ title: String, symbol: String, detail: String, enabled: Bool,
                      action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: action) {
                Label(title, systemImage: symbol).frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(!enabled)
            Text(detail).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder var outputPanel: some View {
        if !runner.output.isEmpty {
            ScrollView {
                Text(runner.output).font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            .frame(height: 260)
            .padding(6)
            .background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Button("Copy output") { store.copy(runner.output, what: "run output") }
                if let f = runner.finished {
                    Button("Open log file") { store.openFile(f.logFile) }
                    Text(f.ok ? "Finished ok in \(String(format: "%.1f", f.finishedSeconds))s"
                              : "Exited \(f.exitCode) after \(String(format: "%.1f", f.finishedSeconds))s")
                        .font(.caption).foregroundStyle(f.ok ? Color.green : Color.red)
                }
            }
        }
    }

    func modeEditor(_ title: String, _ value: Binding<String?>, hint: String) -> some View {
        HStack {
            Toggle(title, isOn: Binding(get: { value.wrappedValue != nil },
                                        set: { value.wrappedValue = $0 ? "" : nil }))
                .frame(width: 130, alignment: .leading)
            if value.wrappedValue != nil {
                TextField(hint, text: Binding(get: { value.wrappedValue ?? "" }, set: { value.wrappedValue = $0 }))
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    Image(systemName: "terminal").font(.title)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.displayName).font(.title2.bold())
                        Text("\(item.kind.label) · \(item.folder) · modified \(relative(item.modified))")
                            .foregroundStyle(.secondary)
                        if !item.summary.isEmpty { Text(item.summary).padding(.top, 2) }
                    }
                    Spacer()
                    Button {
                        entry.favorite.toggle(); store.saveScript(entry)
                    } label: {
                        Image(systemName: entry.favorite ? "star.fill" : "star")
                    }.buttonStyle(.borderless).foregroundStyle(.yellow)
                }

                actionsBox

                DisclosureGroup("Advanced: run with your own arguments") {
                    HStack {
                        TextField("Arguments (optional)", text: $args).frame(maxWidth: 320)
                        Button("Run script") { pendingRun = PendingRun(label: "Run", args: args) }
                        Button("Open in editor") { store.openFile(item.path) }
                        Button("Reveal") { store.reveal(item.path) }
                    }.padding(.top, 6)
                    Text(item.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }

                sectionBox("What it does") {
                    TextField("Description (saved to scripts.json)", text: $entry.whatItDoes, axis: .vertical)
                        .lineLimit(2...5)
                    TextField("Notes: when to run it, gotchas, how you fixed it last time", text: $entry.notes, axis: .vertical)
                        .lineLimit(2...8)
                    TextField("Default arguments", text: $entry.defaultArguments)
                    Text("Set up the buttons").font(.subheadline.weight(.medium)).padding(.top, 4)
                    Text("Turn on an action and type the arguments the script needs for it (leave blank to run with none).")
                        .font(.caption).foregroundStyle(.secondary)
                    modeEditor("Launch", $entry.launchArgs, hint: "e.g. open")
                    modeEditor("Install", $entry.installArgs, hint: "e.g. install")
                    modeEditor("Repair", $entry.repairArgs, hint: "e.g. doctor or --fix")
                    TextField("App to open for Launch (optional, e.g. ~/Applications/Sunlight.app)",
                              text: Binding(get: { entry.launchApp ?? "" }, set: { entry.launchApp = $0.isEmpty ? nil : $0 }))
                    HStack {
                        Button("Save") { store.saveScript(entry) }
                        Button("Remove from Backstage") { store.track(item, on: false) }
                        Spacer()
                        Text("scripts.json in root/mac-scripts/backstage").font(.caption).foregroundStyle(.secondary)
                    }
                }

                sectionBox("Run history") {
                    let runs = store.runs(of: item.path)
                    if runs.isEmpty { Text("Not run from Backstage yet.").foregroundStyle(.secondary) }
                    ForEach(runs.prefix(12)) { r in
                        HStack {
                            Image(systemName: r.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(r.ok ? Color.green : Color.red)
                            Text(r.started.formatted(date: .abbreviated, time: .shortened))
                            Text("\(String(format: "%.1f", r.finishedSeconds))s").foregroundStyle(.secondary)
                            Spacer()
                            Button("Log") { store.openFile(r.logFile) }.controlSize(.small)
                        }
                        .font(.callout)
                    }
                }

                sectionBox("Source") {
                    Text(head(of: item.path)).font(.caption2.monospaced()).textSelection(.enabled)
                }
            }
            .padding(24)
        }
        .onAppear {
            entry = store.scriptEntries[item.path]
                ?? ScriptEntry(path: item.path, name: item.name, whatItDoes: item.autoSummary)
            args = entry.defaultArguments
        }
        .confirmationDialog(pendingRun.map { "\($0.label) \(item.displayName)?" } ?? "",
                            isPresented: Binding(get: { pendingRun != nil }, set: { if !$0 { pendingRun = nil } }),
                            titleVisibility: .visible, presenting: pendingRun) { p in
            Button("\(p.label) now") { start(p.label, p.args) }
        } message: { p in
            Text("This runs on your Mac with your user account:\n\(item.path)\(p.args.isEmpty ? "" : " " + p.args)")
        }
    }

    func head(of path: String) -> String {
        guard let h = FileHandle(forReadingAtPath: path) else { return "(unreadable)" }
        defer { try? h.close() }
        let d = (try? h.read(upToCount: 4000)) ?? Data()
        return String(decoding: d, as: UTF8.self)
    }
}

struct DiscoverView: View {
    @EnvironmentObject var store: JobStore
    @State private var results: [ScriptItem] = []
    @State private var filter = ""
    @State private var onlyUntracked = false

    var shown: [ScriptItem] {
        results.filter { r in
            (filter.isEmpty || r.path.localizedCaseInsensitiveContains(filter)
                || r.summary.localizedCaseInsensitiveContains(filter))
            && (!onlyUntracked || store.scriptEntries[r.path] == nil)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Find scripts on this Mac").font(.title2.bold())
            Text("Backstage looks for .sh, .command, .py, .mjs, .applescript, .swift and .rb files in these folders, skipping node_modules, .git and build folders. Add the ones you want to keep on hand.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            ForEach(store.searchRoots, id: \.self) { root in
                HStack {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(root.replacingOccurrences(of: Scanner.home, with: "~")).font(.callout.monospaced())
                    Spacer()
                    Button("Remove") { store.searchRoots.removeAll { $0 == root } }.controlSize(.small)
                }
            }
            HStack {
                Button("Add folder…") { addFolder() }
                Button(store.discovering ? "Scanning…" : "Scan now") {
                    store.discover { results = $0 }
                }.disabled(store.discovering)
                if store.discovering { ProgressView().controlSize(.small) }
                Spacer()
                Toggle("Only ones I haven't added", isOn: $onlyUntracked)
            }
            TextField("Filter results", text: $filter)

            if results.isEmpty {
                ContentUnavailableView("No scan yet", systemImage: "magnifyingglass",
                                       description: Text("Press “Scan now” to look for scripts."))
                    .frame(maxHeight: .infinity)
            } else {
                Text("\(shown.count) scripts").font(.caption).foregroundStyle(.secondary)
                List { ForEach(shown) { s in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.name).font(.body.weight(.medium))
                            Text(s.folder).font(.caption.monospaced()).foregroundStyle(.secondary)
                            if !s.autoSummary.isEmpty {
                                Text(s.autoSummary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        Spacer()
                        Text(relative(s.modified)).font(.caption).foregroundStyle(.tertiary)
                        if store.scriptEntries[s.path] != nil {
                            Text("added").font(.caption).foregroundStyle(.green)
                        } else {
                            Button("Add") { store.track(s) }
                        }
                    }
                    .padding(.vertical, 2)
                } }
            }
        }
        .padding(24)
    }

    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            if !store.searchRoots.contains(url.path) { store.searchRoots.append(url.path) }
        }
    }
}

// MARK: - Jobs

struct JobDetailView: View {
    @EnvironmentObject var store: JobStore
    let job: Job
    @State private var note = JobNote()
    @State private var logText: [String: String] = [:]
    @State private var confirmUnload = false
    @State private var repairs: [RepairAction] = []
    @State private var chosenCandidate: [UUID: String] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                actions
                if !store.lastActionOutput.isEmpty {
                    Text(store.lastActionOutput).font(.caption.monospaced())
                        .foregroundStyle(.secondary).textSelection(.enabled)
                }

                sectionBox("Diagnosis") {
                    if job.issues.isEmpty {
                        Label("No problems detected", systemImage: "checkmark.circle").foregroundStyle(.green)
                    }
                    ForEach(job.issues.sorted { $0.severity > $1.severity }) { issue in
                        HStack(alignment: .top) {
                            HealthDot(health: issue.severity)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(issue.text).textSelection(.enabled)
                                if let fix = issue.fix {
                                    Text(fix).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                        }
                    }
                }

                if !repairs.isEmpty {
                    sectionBox("Repair") {
                        ForEach(repairs) { r in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(r.title).font(.body.weight(.medium))
                                Text(r.detail).font(.callout).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                if !r.candidates.isEmpty {
                                    Picker("Found at", selection: Binding(
                                        get: { chosenCandidate[r.id] ?? r.candidates.first! },
                                        set: { chosenCandidate[r.id] = $0 })) {
                                        ForEach(r.candidates, id: \.self) { c in
                                            Text(c.replacingOccurrences(of: Scanner.home, with: "~")).tag(c)
                                        }
                                    }
                                    .labelsHidden()
                                    Button("Apply fix") {
                                        store.applyRepair(r, on: job, chosenCandidate: chosenCandidate[r.id] ?? r.candidates.first)
                                        reloadRepairs()
                                    }
                                } else if case .replacePath = r.kind {
                                    Text("Nothing to apply automatically.").font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Button(r.title) {
                                        store.applyRepair(r, on: job, chosenCandidate: nil)
                                        reloadRepairs()
                                    }
                                }
                                Divider()
                            }
                        }
                    }
                }

                sectionBox("What it does") {
                    TextField("Describe what this job does (saved to job-notes.json)", text: $note.whatItDoes, axis: .vertical)
                        .lineLimit(2...5)
                    TextField("Notes: why it exists, how to fix it, who set it up", text: $note.notes, axis: .vertical)
                        .lineLimit(2...8)
                    HStack {
                        Button("Save notes") { store.saveNote(note, for: job.label) }
                        Text("job-notes.json in root/mac-scripts/backstage").font(.caption).foregroundStyle(.secondary)
                    }
                }

                sectionBox("Definition") { grid }

                sectionBox("Recent activity (log tails)") {
                    if job.logs.isEmpty { Text("No logs configured.").foregroundStyle(.secondary) }
                    ForEach(job.logs, id: \.path) { log in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("\(log.kind) · updated \(relative(Scanner.modDate(log.path)))").font(.caption.bold())
                                Spacer()
                                Button("Open") { store.openFile(log.path) }.controlSize(.small)
                                Button("Reveal") { store.reveal(log.path) }.controlSize(.small)
                            }
                            Text(log.path).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            ScrollView {
                                Text(logText[log.path] ?? "Loading…").font(.caption.monospaced())
                                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                            }
                            .frame(height: 170)
                            .padding(6)
                            .background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }

                sectionBox("Raw definition") {
                    Text(job.rawPlist).font(.caption2.monospaced()).textSelection(.enabled)
                }
            }
            .padding(24)
        }
        .onAppear(perform: load)
    }

    func load() {
        note = store.notes[job.label] ?? JobNote(whatItDoes: job.summary)
        let logs = job.logs
        Task.detached {
            var result: [String: String] = [:]
            for l in logs { result[l.path] = Scanner.tail(l.path) }
            let final = result
            await MainActor.run { logText = final }
        }
        reloadRepairs()
    }

    func reloadRepairs() {
        let j = job
        Task.detached {
            let r = Repair.actions(for: j)
            await MainActor.run { repairs = r }
        }
    }

    var header: some View {
        HStack(alignment: .top) {
            HealthDot(health: job.health).font(.title)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.displayName).font(.title2.bold()).textSelection(.enabled)
                Text("\(job.health.word) · \(job.statusLine) · last activity \(relative(job.lastActivity))")
                    .foregroundStyle(.secondary)
                let d = store.description(for: job)
                if !d.isEmpty { Text(d).padding(.top, 2) }
            }
        }
    }

    var actions: some View {
        HStack {
            if job.source == .userAgent {
                if job.loaded == true {
                    Button("Run now / Restart") { store.runNow(job) }
                    Button("Unload…") { confirmUnload = true }
                } else {
                    Button("Load") { store.load(job) }
                }
            }
            if let p = job.plistPath { Button("Reveal definition") { store.reveal(p) } }
            Button("Copy diagnosis for AI") { store.copy(store.diagnosisReport(job), what: "diagnosis") }
        }
        .confirmationDialog("Unload \(job.label)? It stops running until loaded again.",
                            isPresented: $confirmUnload) {
            Button("Unload", role: .destructive) { store.unload(job) }
        }
    }

    var grid: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            row("Label", job.label)
            row("Source", job.source.rawValue)
            row("Schedule", job.schedule)
            row("Command", job.program.joined(separator: " "))
            if let p = job.plistPath { row("File", p) }
            if let r = job.runs { row("Runs since boot", "\(r)") }
            if let e = job.lastExit { row("Last exit", e) }
        }
    }

    func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).font(.callout.monospaced()).textSelection(.enabled)
        }
    }
}

// MARK: - Menu bar

struct MenuBarView: View {
    @EnvironmentObject var store: JobStore
    @Environment(\.openWindow) private var openWindow

    func open(_ sel: Selection) {
        store.pendingSelection = sel
        openWindow(id: "dashboard")
        NSApp.activate(ignoringOtherApps: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Backstage").font(.headline)
                Spacer()
                if store.scanning { ProgressView().controlSize(.small) }
            }
            let favs = store.trackedScripts.filter { $0.entry?.favorite == true }
            let scripts = favs.isEmpty ? Array(store.trackedScripts.prefix(6)) : favs
            if !scripts.isEmpty {
                Text("Scripts").font(.caption).foregroundStyle(.secondary)
                ForEach(scripts) { s in
                    Button { open(.script(s.path)) } label: {
                        HStack {
                            Image(systemName: "terminal")
                            Text(s.displayName).lineLimit(1)
                            Spacer()
                            if let r = s.lastRun {
                                Text(r.ok ? relative(r.started) : "exit \(r.exitCode)")
                                    .font(.caption).foregroundStyle(r.ok ? Color.secondary : Color.red)
                            }
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                Divider()
            }
            Text("Background jobs").font(.caption).foregroundStyle(.secondary)
            ForEach(store.jobs.filter { !$0.isVendor }.sorted { $0.health > $1.health }) { job in
                Button { open(.job(job.id)) } label: {
                    HStack(alignment: .top, spacing: 6) {
                        HealthDot(health: job.health)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(job.displayName).lineLimit(1)
                            Text("\(job.statusLine) · \(relative(job.lastActivity))")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            Divider()
            HStack {
                Button("Open command center") { open(.overview) }
                Button(store.missingRequiredCount > 0 ? "Setup (\(store.missingRequiredCount))" : "Setup") { open(.setup) }
                Button("Refresh") { store.refresh() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 380)
    }
}


struct OverviewScriptRow: View {
    let item: ScriptItem
    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: item.entry?.favorite == true ? "star.fill" : "terminal")
                .foregroundStyle(item.entry?.favorite == true ? Color.yellow : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName).font(.body.weight(.medium))
                Text(item.summary.isEmpty ? item.path : item.summary)
                    .font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if let r = item.lastRun {
                Text(r.ok ? "ok · " + relative(r.started) : "exit \(r.exitCode)")
                    .font(.caption).foregroundStyle(r.ok ? Color.secondary : Color.red)
            }
        }
        .contentShape(Rectangle())
    }
}


// MARK: - New Mac setup

struct SetupView: View {
    @EnvironmentObject var store: JobStore
    let select: (Selection) -> Void

    var groups: [String] {
        var seen: [String] = []
        for i in store.setupItems where !seen.contains(i.group) { seen.append(i.group) }
        return seen
    }

    var migratorPath: String { SetupChecker.resolve("mac-scripts/mac-migrator/mac_background_migrator.sh") }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("New Mac setup").font(.largeTitle.bold())
                    Spacer()
                    Button { store.loadSetup() } label: { Label("Check again", systemImage: "arrow.clockwise") }
                }
                Text("Backstage checks this Mac against setup.json (next to the app source, synced by iCloud). "
                     + "Press Fix on anything missing. Steps that need your password open in Terminal.")
                    .foregroundStyle(.secondary)

                GroupBox {
                    Toggle("Start Backstage automatically at login", isOn: Binding(
                        get: { store.startsAtLogin }, set: { store.setStartsAtLogin($0) }))
                        .padding(4)
                }

                ForEach(groups, id: \.self) { group in
                    Text(group).font(.headline).padding(.top, 4)
                    ForEach(store.setupItems.filter { $0.group == group }) { item in
                        SetupRow(item: item)
                        Divider()
                    }
                }

                Text("Move to another Mac").font(.headline).padding(.top, 8)
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Mac Migrator bundles this Mac's LaunchAgents, shell and git config, and Homebrew list into a folder you can carry over. "
                             + "Run it on the old Mac, copy the bundle to the new one, and run its installer/install.sh there. "
                             + "Your scripts, notes and this checklist already travel with iCloud.")
                            .font(.callout).foregroundStyle(.secondary)
                        HStack {
                            Button("Open Mac Migrator") { select(.script(migratorPath)) }
                                .disabled(!FileManager.default.fileExists(atPath: migratorPath))
                            Button("Show migration bundles") {
                                store.reveal(Scanner.home)
                            }
                            Button("Copy setup report for an AI") {
                                store.copy(setupReport(), what: "the setup report")
                            }
                        }
                    }.padding(4)
                }

                if !store.setupOutput.isEmpty {
                    Text("Output").font(.headline).padding(.top, 8)
                    ScrollView {
                        Text(store.setupOutput)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(minHeight: 120, maxHeight: 260)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(24)
        }
        .onAppear {
            UserDefaults.standard.set(true, forKey: "setupSeen")
            store.checkSetup()
        }
    }

    func setupReport() -> String {
        var s = "# New Mac setup status\n"
        for i in store.setupItems {
            let st = store.status(of: i)
            s += "- [\(st == .ok ? "x" : " ")] \(i.name)\(i.isOptional ? " (optional)" : ""): \(i.why)\n"
        }
        s += "\nManifest: \(JobStore.setupPath)\nContext: see ~/Documents/root/AI-README.md\n"
        return s
    }
}

struct SetupRow: View {
    @EnvironmentObject var store: JobStore
    let item: SetupItem

    var body: some View {
        let st = store.status(of: item)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: st == .ok ? "checkmark.circle.fill" : (st == .missing ? "circle.dashed" : "questionmark.circle"))
                .foregroundStyle(st == .ok ? Color.green : (item.isOptional ? Color.secondary : Color.orange))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name + (item.isOptional ? "  (optional)" : "")).font(.body.weight(.medium))
                Text(item.why).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if store.setupBusy == item.id {
                ProgressView().controlSize(.small)
            } else if st != .ok, item.fix != nil {
                Button("Fix") { store.fix(item) }.disabled(store.setupBusy != nil)
            }
        }
    }
}
