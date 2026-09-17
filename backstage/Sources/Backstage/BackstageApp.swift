import SwiftUI

@main
struct BackstageApp: App {
    @StateObject private var store = JobStore()

    init() {
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
            DashboardView().environmentObject(store)
        }

        MenuBarExtra {
            MenuBarView().environmentObject(store)
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
