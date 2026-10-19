import SwiftUI

// MARK: - List

struct RecipesListView: View {
    @EnvironmentObject var store: JobStore
    let select: (Selection) -> Void
    @State private var showNewSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recipes").font(.title2.bold())
                Spacer()
                Menu {
                    Button("Blank recipe") { newBlank() }
                    Button("From what New Mac setup is missing") { newFromSetup() }
                } label: {
                    Label("New recipe", systemImage: "plus")
                }
                .menuStyle(.borderedButton)
            }
            Text("A recipe is an ordered list of setup fixes and scripts you can replay in one go — to bring a fresh Mac up to speed, or to re-run everything that keeps a flaky job (like the light bulb controller) working, without clicking each button by hand.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if store.recipes.isEmpty {
                ContentUnavailableView {
                    Label("No recipes yet", systemImage: "list.bullet.clipboard")
                } description: {
                    Text("Make one from the missing New Mac setup items, or start blank and add script/setup steps.")
                } actions: {
                    Button("From what New Mac setup is missing") { newFromSetup() }.buttonStyle(.borderedProminent)
                    Button("Blank recipe") { newBlank() }
                }
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(store.recipes) { r in
                        RecipeRow(recipe: r, lastRun: store.lastRun(ofRecipe: r.id))
                            .contentShape(Rectangle())
                            .onTapGesture { select(.recipe(r.id)) }
                            .contextMenu {
                                Button("Run now") { select(.recipe(r.id)) }
                                Button("Duplicate") { _ = store.duplicateRecipe(r) }
                                Button("Delete", role: .destructive) { store.deleteRecipe(r.id) }
                            }
                    }
                }
            }
        }
        .padding(24)
    }

    func newBlank() {
        let r = Recipe(name: "New recipe")
        store.saveRecipe(r)
        select(.recipe(r.id))
    }

    func newFromSetup() {
        let r = store.draftFullSetupRecipe()
        store.saveRecipe(r)
        select(.recipe(r.id))
    }
}

struct RecipeRow: View {
    let recipe: Recipe
    let lastRun: RecipeRun?
    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "list.bullet.clipboard").foregroundStyle(.secondary).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(recipe.name).font(.body.weight(.medium))
                Text(recipe.summary.isEmpty ? "\(recipe.steps.count) step\(recipe.steps.count == 1 ? "" : "s")" : recipe.summary)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if let r = lastRun {
                    Text("last run \(relative(r.started)) · \(r.ok) ok" + (r.failed > 0 ? " · \(r.failed) failed" : ""))
                        .font(.caption2).foregroundStyle(r.failed > 0 ? Color.red : Color.secondary)
                }
            }
            Spacer()
            Text("\(recipe.steps.count)").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Detail (run + edit)

struct RecipeDetailView: View {
    @EnvironmentObject var store: JobStore
    @StateObject private var runner = RecipeRunner()
    let recipeID: String
    @State private var recipe = Recipe(name: "")
    @State private var confirmRun = false
    @State private var confirmDelete = false

    var live: Recipe { store.recipes.first(where: { $0.id == recipeID }) ?? recipe }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                runBox
                if let step = runner.awaitingManual { manualBox(step) }
                if !runner.output.isEmpty { outputBox }
                sectionBox("Steps") { stepsEditor }
                sectionBox("Options") {
                    Toggle("Stop the recipe on the first failed step", isOn: Binding(
                        get: { live.stopOnError }, set: { var r = live; r.stopOnError = $0; store.saveRecipe(r) }))
                }
                sectionBox("Run history") { historyBox }
                HStack {
                    Spacer()
                    Button("Delete recipe", role: .destructive) { confirmDelete = true }
                        .confirmationDialog("Delete “\(live.name)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
                            Button("Delete", role: .destructive) { store.deleteRecipe(recipeID) }
                        }
                }
            }
            .padding(24)
        }
        .onAppear { recipe = live }
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Recipe name", text: Binding(get: { live.name }, set: { var r = live; r.name = $0; store.saveRecipe(r) }))
                .font(.title2.bold()).textFieldStyle(.plain)
            TextField("What this recipe is for (optional)", text: Binding(get: { live.summary }, set: { var r = live; r.summary = $0; store.saveRecipe(r) }), axis: .vertical)
                .foregroundStyle(.secondary)
        }
    }

    var runBox: some View {
        sectionBox("Run") {
            HStack(spacing: 12) {
                Button {
                    if runner.running { return }
                    confirmRun = true
                } label: {
                    Label(runner.running ? "Running…" : "Run this recipe", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(runner.running || live.steps.isEmpty)
                .confirmationDialog("Run “\(live.name)” now?", isPresented: $confirmRun, titleVisibility: .visible) {
                    Button("Run \(live.steps.count) step\(live.steps.count == 1 ? "" : "s")") { runner.run(live, store: store) }
                } message: {
                    Text("This runs each step on your Mac with your user account, in order.")
                }
                if runner.running { Button("Stop", role: .destructive) { runner.stop() } }
                if let s = runner.finishedSummary, !runner.running { Text(s).font(.caption).foregroundStyle(.secondary) }
                Spacer()
            }
            if live.steps.isEmpty {
                Text("Add at least one step below before running.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(live.steps) { step in
                    HStack(spacing: 8) {
                        stepStatusIcon(runner.states[step.id] ?? .pending)
                        Text(step.title).font(.callout)
                            .foregroundStyle(runner.currentStepID == step.id ? Color.primary : Color.primary.opacity(0.85))
                        if case .failed(let why) = runner.states[step.id] ?? .pending {
                            Text(why).font(.caption).foregroundStyle(.red)
                        }
                        if case .manual(let why) = runner.states[step.id] ?? .pending {
                            Text(why).font(.caption).foregroundStyle(.orange)
                        }
                        Spacer()
                    }
                }
            }
        }
    }

    @ViewBuilder func stepStatusIcon(_ s: RecipeRunner.StepState) -> some View {
        switch s {
        case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running: ProgressView().controlSize(.mini)
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .skipped: Image(systemName: "arrow.turn.up.right").foregroundStyle(.secondary)
        case .manual: Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
        }
    }

    func manualBox(_ step: RecipeStep) -> some View {
        sectionBox("Needs you") {
            Text(step.title).font(.body.weight(.medium))
            if !step.note.isEmpty { Text(step.note).foregroundStyle(.secondary) }
            Text("Backstage opened what this step needs (a URL or a Terminal window). Finish it there, then come back and continue.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Done, continue") { runner.resumeManual(verified: true) }.buttonStyle(.borderedProminent)
                Button("Skip this step") { runner.resumeManual(verified: false) }
            }
        }
        .padding(12)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    var outputBox: some View {
        sectionBox("Output") {
            ScrollView {
                Text(runner.output).font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            .frame(height: 220)
            .padding(6)
            .background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    var historyBox: some View {
        let runs = store.recipeRuns.filter { $0.recipeID == recipeID }
        return Group {
            if runs.isEmpty {
                Text("Not run yet.").foregroundStyle(.secondary)
            } else {
                ForEach(runs.prefix(10)) { r in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Image(systemName: r.failed == 0 ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(r.failed == 0 ? Color.green : Color.red)
                            Text(r.started.formatted(date: .abbreviated, time: .shortened))
                            Text("\(String(format: "%.0f", r.finishedSeconds))s").foregroundStyle(.secondary)
                            Spacer()
                            Text("\(r.ok) ok" + (r.failed > 0 ? " · \(r.failed) failed" : "") + (r.manual > 0 ? " · \(r.manual) manual" : "") + (r.skipped > 0 ? " · \(r.skipped) skipped" : ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if r.failed > 0 {
                            Text(r.stepLog.filter { $0.hasPrefix("✗") }.joined(separator: "\n"))
                                .font(.caption2.monospaced()).foregroundStyle(.red)
                        }
                    }
                    .font(.callout)
                    Divider()
                }
            }
        }
    }

    // MARK: step editor

    var stepsEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(live.steps.enumerated()), id: \.element.id) { idx, step in
                StepEditorRow(step: step, index: idx, count: live.steps.count,
                             onChange: { updated in var r = live; r.steps[idx] = updated; store.saveRecipe(r) },
                             onMove: { delta in
                                 var r = live
                                 let j = idx + delta
                                 guard r.steps.indices.contains(j) else { return }
                                 r.steps.swapAt(idx, j)
                                 store.saveRecipe(r)
                             },
                             onDelete: { var r = live; r.steps.remove(at: idx); store.saveRecipe(r) })
                Divider()
            }
            AddStepRow { step in var r = live; r.steps.append(step); store.saveRecipe(r) }
        }
    }
}

private struct StepEditorRow: View {
    @EnvironmentObject var store: JobStore
    let step: RecipeStep
    let index: Int
    let count: Int
    let onChange: (RecipeStep) -> Void
    let onMove: (Int) -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 2) {
                Button { onMove(-1) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless).disabled(index == 0)
                Button { onMove(1) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless).disabled(index == count - 1)
            }.font(.caption)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(step.kind.label).font(.caption2).padding(.horizontal, 5).background(.quaternary, in: Capsule())
                    Text(step.title).font(.body.weight(.medium))
                }
                if step.kind == .script {
                    Picker("", selection: Binding(get: { step.scriptAction }, set: { var s = step; s.scriptAction = $0; onChange(s) })) {
                        Text("Launch").tag("launch"); Text("Install").tag("install")
                        Text("Repair").tag("repair"); Text("Custom args").tag("custom")
                    }.labelsHidden().frame(width: 160).pickerStyle(.menu)
                    if step.scriptAction == "custom" {
                        TextField("Arguments", text: Binding(get: { step.args }, set: { var s = step; s.args = $0; onChange(s) }))
                            .frame(width: 220)
                    }
                }
                if step.kind == .shell {
                    TextField("Shell command", text: Binding(get: { step.args }, set: { var s = step; s.args = $0; onChange(s) }))
                    TextField("Label (optional)", text: Binding(get: { step.note }, set: { var s = step; s.note = $0; onChange(s) }))
                }
            }
            Spacer()
            Button(role: .destructive) { onDelete() } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }
}

private struct AddStepRow: View {
    @EnvironmentObject var store: JobStore
    let onAdd: (RecipeStep) -> Void
    @State private var kind: RecipeStepKind = .setup
    @State private var setupID: String = ""
    @State private var scriptPath: String = ""
    @State private var shellCommand: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add a step").font(.subheadline.weight(.medium))
            Picker("", selection: $kind) {
                ForEach(RecipeStepKind.allCases, id: \.self) { Text($0.label).tag($0) }
            }.labelsHidden().pickerStyle(.segmented).frame(width: 320)

            switch kind {
            case .setup:
                if store.setupItems.isEmpty {
                    Text("No New Mac setup items defined.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("Setup item", selection: $setupID) {
                        Text("Choose one…").tag("")
                        ForEach(store.setupItems) { i in Text("\(i.group) — \(i.name)").tag(i.id) }
                    }.frame(width: 340)
                    Button("Add") { onAdd(RecipeStep(kind: .setup, ref: setupID)); setupID = "" }
                        .disabled(setupID.isEmpty)
                }
            case .script:
                if store.trackedScripts.isEmpty {
                    Text("No scripts tracked yet — add some from “Find scripts on this Mac”.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("Script", selection: $scriptPath) {
                        Text("Choose one…").tag("")
                        ForEach(store.trackedScripts) { s in Text(s.displayName).tag(s.path) }
                    }.frame(width: 340)
                    Button("Add") { onAdd(RecipeStep(kind: .script, ref: scriptPath)); scriptPath = "" }
                        .disabled(scriptPath.isEmpty)
                }
            case .shell:
                TextField("Shell command", text: $shellCommand).frame(width: 340)
                Button("Add") { onAdd(RecipeStep(kind: .shell, args: shellCommand)); shellCommand = "" }
                    .disabled(shellCommand.isEmpty)
            }
        }
        .padding(.top, 6)
    }
}
