import AppKit
import Foundation

// MARK: - Model
//
// A Recipe is a named, ordered list of steps that "re-flash the bulb": reprovision a Mac by
// replaying the same fixes/scripts you'd otherwise click one at a time. Steps reuse the existing
// building blocks (New Mac setup items, tracked scripts) instead of inventing a new execution
// path, so a recipe step behaves exactly like pressing that button by hand.

enum RecipeStepKind: String, Codable, CaseIterable {
    case setup   // run a New Mac setup item's fix, by id
    case script  // run a tracked script, by path
    case shell   // raw shell command (escape hatch for one-off steps)

    var label: String {
        switch self {
        case .setup: return "Setup item"
        case .script: return "Script"
        case .shell: return "Shell command"
        }
    }
}

struct RecipeStep: Codable, Hashable, Identifiable {
    var id: String = UUID().uuidString
    var kind: RecipeStepKind
    var ref: String = ""              // setup item id, or script path
    var scriptAction: String = "launch"  // for .script: launch | install | repair | custom
    var args: String = ""             // .shell: the command. .script + custom: arguments.
    var note: String = ""             // optional free-text shown while running (why this step exists)

    var title: String {
        switch kind {
        case .setup: return ref
        case .script: return (ref as NSString).lastPathComponent + (scriptAction == "custom" ? "" : " (\(scriptAction))")
        case .shell: return note.isEmpty ? args : note
        }
    }
}

struct Recipe: Codable, Hashable, Identifiable {
    var id: String = UUID().uuidString
    var name: String
    var summary: String = ""
    var steps: [RecipeStep] = []
    var stopOnError: Bool = true
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
}

struct RecipeRun: Codable, Hashable, Identifiable {
    var id: String { started.description + recipeID }
    var recipeID: String
    var recipeName: String
    var started: Date
    var finishedSeconds: Double
    var ok: Int
    var failed: Int
    var skipped: Int
    var manual: Int
    var stepLog: [String] = []   // one line per step: "✓ Homebrew" / "✗ Homebrew: exit 1" / "… CPU guard: opened Terminal"
}

// MARK: - Store

extension JobStore {
    static var recipesPath: String { dataDirectory + "/recipes.json" }
    static var recipeRunsPath: String { dataDirectory + "/recipe-runs.json" }

    func loadRecipes() {
        if let data = FileManager.default.contents(atPath: Self.recipesPath),
           let decoded = try? JSONDecoder().decode([Recipe].self, from: data) {
            recipes = decoded
        }
        if let data = FileManager.default.contents(atPath: Self.recipeRunsPath) {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            if let decoded = (try? dec.decode([RecipeRun].self, from: data))
                ?? (try? JSONDecoder().decode([RecipeRun].self, from: data)) {
                recipeRuns = decoded
            }
        }
    }

    func saveRecipe(_ r: Recipe) {
        var r = r
        r.updatedAt = Date()
        if let i = recipes.firstIndex(where: { $0.id == r.id }) { recipes[i] = r } else { recipes.append(r) }
        persistRecipes()
    }

    func deleteRecipe(_ id: String) {
        recipes.removeAll { $0.id == id }
        persistRecipes()
    }

    func duplicateRecipe(_ r: Recipe) -> Recipe {
        var copy = r
        copy.id = UUID().uuidString
        copy.name = r.name + " copy"
        copy.createdAt = Date(); copy.updatedAt = Date()
        recipes.append(copy)
        persistRecipes()
        return copy
    }

    private func persistRecipes() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(atPath: Self.dataDirectory, withIntermediateDirectories: true)
        if let data = try? enc.encode(recipes) { try? data.write(to: URL(fileURLWithPath: Self.recipesPath), options: .atomic) }
    }

    func recordRecipeRun(_ run: RecipeRun) {
        recipeRuns.insert(run, at: 0)
        recipeRuns = Array(recipeRuns.prefix(100))
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(recipeRuns) { try? data.write(to: URL(fileURLWithPath: Self.recipeRunsPath), options: .atomic) }
    }

    func lastRun(ofRecipe id: String) -> RecipeRun? { recipeRuns.first { $0.recipeID == id } }

    /// Builds (but doesn't save) a starter recipe from the current New Mac setup checklist:
    /// every non-optional item that's currently missing, in checklist order. This is the
    /// "re-flash the bulb" recipe — run it on a fresh or misbehaving Mac to catch it up.
    func draftFullSetupRecipe() -> Recipe {
        let items = setupItems.filter { !$0.isOptional && status(of: $0) != .ok }
        let steps = items.map { RecipeStep(kind: .setup, ref: $0.id, note: $0.why) }
        return Recipe(name: "Full Mac setup", summary: "Everything New Mac setup currently flags as missing, in order.", steps: steps)
    }
}

// MARK: - Runner

@MainActor
final class RecipeRunner: ObservableObject {
    enum StepState: Equatable {
        case pending, running, ok, failed(String), skipped, manual(String)
    }

    enum Outcome { case ok, failed(String), manual(String), skipped }

    @Published var running = false
    @Published var states: [String: StepState] = [:]   // keyed by RecipeStep.id
    @Published var currentStepID: String? = nil
    @Published var output = ""
    @Published var awaitingManual: RecipeStep? = nil
    @Published var finishedSummary: String? = nil

    private var process: Process?
    private var stopRequested = false
    private var continuation: CheckedContinuation<Void, Never>?

    func reset(for recipe: Recipe) {
        states = Dictionary(uniqueKeysWithValues: recipe.steps.map { ($0.id, .pending) })
        output = ""
        finishedSummary = nil
        currentStepID = nil
    }

    func stop() {
        stopRequested = true
        process?.terminate()
        if let c = continuation { continuation = nil; c.resume() }
    }

    /// Called from the UI after the person finishes a manual step (opened URL / ran Terminal command).
    func resumeManual(verified: Bool) {
        guard let step = awaitingManual else { return }
        states[step.id] = verified ? .ok : .skipped
        awaitingManual = nil
        if let c = continuation { continuation = nil; c.resume() }
    }

    func run(_ recipe: Recipe, store: JobStore) {
        guard !running else { return }
        running = true
        stopRequested = false
        reset(for: recipe)
        let started = Date()
        Task {
            var ok = 0, failed = 0, skipped = 0, manual = 0
            var log: [String] = []
            for step in recipe.steps {
                if stopRequested { states[step.id] = .skipped; skipped += 1; log.append("… \(step.title): stopped before running"); continue }
                currentStepID = step.id
                states[step.id] = .running
                append("\n— \(step.title) —\n")
                let outcome = await execute(step, store: store)
                switch outcome {
                case .ok:
                    states[step.id] = .ok; ok += 1; log.append("✓ \(step.title)")
                case .failed(let why):
                    states[step.id] = .failed(why); failed += 1; log.append("✗ \(step.title): \(why)")
                    if recipe.stopOnError { stopRequested = true }
                case .manual(let what):
                    // Pause and let the person act, then resume() decides ok/skipped.
                    states[step.id] = .manual(what)
                    awaitingManual = step
                    await withCheckedContinuation { c in self.continuation = c }
                    manual += 1
                    log.append("… \(step.title): \(what)")
                    if states[step.id] == .skipped { skipped += 1; manual -= 1 }
                case .skipped:
                    states[step.id] = .skipped; skipped += 1; log.append("– \(step.title): skipped")
                }
            }
            currentStepID = nil
            running = false
            let secs = Date().timeIntervalSince(started)
            finishedSummary = "\(ok) done" + (failed > 0 ? ", \(failed) failed" : "") + (manual > 0 ? ", \(manual) manual" : "") + (skipped > 0 ? ", \(skipped) skipped" : "") + " · \(String(format: "%.0f", secs))s"
            store.recordRecipeRun(RecipeRun(recipeID: recipe.id, recipeName: recipe.name, started: started,
                                            finishedSeconds: secs, ok: ok, failed: failed, skipped: skipped, manual: manual, stepLog: log))
        }
    }

    private func append(_ s: String) { output += s }

    private func execute(_ step: RecipeStep, store: JobStore) async -> Outcome {
        switch step.kind {
        case .shell:
            return await runShell(step.args.isEmpty ? "true" : step.args)
        case .script:
            guard let entry = store.scriptEntries[step.ref] else {
                return .failed("no longer tracked in Backstage: \(step.ref)")
            }
            guard FileManager.default.fileExists(atPath: entry.path) else {
                return .failed("script missing on disk: \(entry.path)")
            }
            let item = ScriptFinder.item(for: entry.path, entry: entry, lastRun: nil, summarize: false)
            let args: String
            switch step.scriptAction {
            case "install": args = entry.installArgs ?? ""
            case "repair": args = entry.repairArgs ?? ""
            case "custom": args = step.args
            default: args = entry.launchArgs ?? entry.defaultArguments
            }
            return await runScriptItem(item, arguments: args)
        case .setup:
            guard let item = store.setupItems.first(where: { $0.id == step.ref }) else {
                return .failed("setup item no longer exists: \(step.ref)")
            }
            if SetupChecker.check(item.check) { return .ok }
            guard let f = item.fix else { return .failed("no automatic fix defined") }
            switch f.type {
            case "brew":
                guard SetupChecker.check(SetupCheck(type: "command", value: "brew")) else {
                    return .failed("Homebrew isn't installed yet — add it earlier in the recipe")
                }
                return await runShell("brew install \(f.value)")
            case "script":
                let parts = f.value.split(separator: " ").map(String.init)
                guard let first = parts.first else { return .failed("empty script fix") }
                let path = SetupChecker.resolve(first)
                guard FileManager.default.fileExists(atPath: path) else { return .failed("script not found: \(path)") }
                let quoted = ([path] + parts.dropFirst()).map { "'\($0)'" }.joined(separator: " ")
                return await runShell("/bin/bash \(quoted)")
            case "url", "note", "terminal":
                if f.type == "terminal" { openTerminal(f.value) }
                else if f.type == "url", let u = URL(string: f.value) { NSWorkspace.shared.open(u) }
                return .manual(f.type == "note" ? f.value : "needs you — see the panel")
            default:
                return .failed("don't know how to run a \"\(f.type)\" fix")
            }
        }
    }

    private func openTerminal(_ command: String) {
        let file = NSTemporaryDirectory() + "backstage-recipe-\(Int(Date().timeIntervalSince1970)).command"
        let body = "#!/bin/bash\n\(command)\necho\necho 'Done. Close this window, then continue the recipe in Backstage.'\n"
        try? body.write(toFile: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file)
        NSWorkspace.shared.open(URL(fileURLWithPath: file))
    }

    private func runScriptItem(_ item: ScriptItem, arguments: String) async -> Outcome {
        let args = arguments.split(separator: " ").map(String.init)
        let p = Process()
        if let (exe, pre) = item.kind.interpreter {
            p.executableURL = URL(fileURLWithPath: exe); p.arguments = pre + [item.path] + args
        } else if item.executable {
            p.executableURL = URL(fileURLWithPath: item.path); p.arguments = args
        } else {
            p.executableURL = URL(fileURLWithPath: "/bin/bash"); p.arguments = [item.path] + args
        }
        p.currentDirectoryURL = URL(fileURLWithPath: (item.path as NSString).deletingLastPathComponent)
        return await runProcess(p)
    }

    private func runShell(_ command: String) async -> Outcome {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", command]
        return await runProcess(p)
    }

    private func runProcess(_ p: Process) async -> Outcome {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            let chunk = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self?.append(chunk) }
        }
        return await withCheckedContinuation { c in
            process = p
            p.terminationHandler = { proc in
                Task { @MainActor in
                    pipe.fileHandleForReading.readabilityHandler = nil
                    self.process = nil
                    if proc.terminationStatus == 0 { c.resume(returning: .ok) }
                    else { c.resume(returning: .failed("exit \(proc.terminationStatus)")) }
                }
            }
            do { try p.run() } catch {
                c.resume(returning: .failed("\(error.localizedDescription)"))
            }
        }
    }
}
