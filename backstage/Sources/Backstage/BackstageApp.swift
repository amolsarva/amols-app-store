import SwiftUI

@main
struct BackstageApp: App {
    @StateObject private var store = JobStore()
    @StateObject private var updater = Updater()

    init() {
        // `Backstage --setup` prints the new-Mac checklist (from setup.json) and exits.
        if CommandLine.arguments.contains("--setup") {
            let data = FileManager.default.contents(atPath: Scanner.documents + "/root/mac-scripts/backstage/setup.json") ?? Data()
            for i in (try? JSONDecoder().decode([SetupItem].self, from: data)) ?? [] {
                print("[\(SetupChecker.check(i.check) ? " ok " : "TODO")] \(i.name)\(i.isOptional ? " (optional)" : "") - \(i.group)")
            }
            exit(0)
        }
        // `Backstage --update-status` shows what the updater compares (build stamp vs newest source file).
        if CommandLine.arguments.contains("--update-status") {
            print("built from source stamp: \(Updater.builtStamp)")
            print("newest source stamp:     \(Updater.newestSourceStamp()) in \(Updater.sourceDir)")
            print("manifest:                \(Updater.manifestURL)")
            exit(0)
        }
        // `Backstage --report` prints a plain-text health report and exits (useful for AIs and terminals).
        if CommandLine.arguments.contains("--report") {
            for job in Scanner.scanAll() where !job.isVendor || CommandLine.arguments.contains("--all") {
                print("[\(job.health.word.uppercased())] \(job.displayName)  (\(job.source.rawValue))")
                print("    schedule: \(job.schedule) | status: \(job.statusLine) | last activity: \(job.lastActivity.map { "\($0)" } ?? "none")")
                for i in job.issues { print("    - \(i.severity.word): \(i.text)") }
            }
            exit(0)
        }
    }

    var body: some Scene {
        Window("Backstage", id: "dashboard") {
            DashboardView().environmentObject(store).environmentObject(updater)
        }

        MenuBarExtra {
            MenuBarView().environmentObject(store).environmentObject(updater)
        } label: {
            let health = store.worstHealth
            if store.problemCount > 0 {
                Label("\(store.problemCount)", systemImage: health.symbol).labelStyle(.titleAndIcon)
            } else {
                Image(systemName: "gearshape.2")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
