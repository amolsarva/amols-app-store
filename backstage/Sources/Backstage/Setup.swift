import AppKit
import Foundation
import ServiceManagement

// MARK: - Portable paths
// scripts.json / run-history.json sync via iCloud between Macs whose usernames may differ
// (/Users/amol vs /Users/MrAnonymous), so paths are stored as ~/… and expanded per Mac.

enum PortablePath {
    static func expand(_ p: String) -> String {
        if p.hasPrefix("~/") { return Scanner.home + String(p.dropFirst(1)) }
        if p.hasPrefix("/Users/") {
            let parts = p.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: true)
            if parts.count == 3, parts[1] != "Shared" { return Scanner.home + "/" + parts[2] }
        }
        return p
    }

    static func portable(_ p: String) -> String {
        p.hasPrefix(Scanner.home + "/") ? "~" + p.dropFirst(Scanner.home.count) : p
    }
}

// MARK: - Manifest

struct SetupCheck: Codable, Hashable { var type: String; var value: String }
struct SetupFix: Codable, Hashable { var type: String; var value: String }

struct SetupItem: Codable, Identifiable, Hashable {
    var id: String
    var group: String
    var name: String
    var why: String
    var optional: Bool? = nil
    var check: SetupCheck
    var fix: SetupFix? = nil

    var isOptional: Bool { optional == true }
}

enum SetupStatus { case unknown, ok, missing }

enum SetupChecker {
    static let brewPaths = ["/opt/homebrew/bin", "/usr/local/bin"]

    static var runPath: String {
        (brewPaths + [Scanner.home + "/.local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
    }

    static func resolve(_ rel: String) -> String {
        let p = (rel as NSString).expandingTildeInPath
        return p.hasPrefix("/") ? p : Scanner.documents + "/root/" + p
    }

    static func check(_ c: SetupCheck) -> Bool {
        let fm = FileManager.default
        switch c.type {
        case "command":
            return (brewPaths + ["/usr/bin", Scanner.home + "/.local/bin"])
                .contains { fm.isExecutableFile(atPath: $0 + "/" + c.value) }
        case "app":
            return ["/Applications", Scanner.home + "/Applications", "/System/Applications"]
                .contains { fm.fileExists(atPath: $0 + "/" + c.value + ".app") }
        case "path":
            return fm.fileExists(atPath: resolve(c.value))
        case "agent":
            return Shell.run("/bin/launchctl", ["print", "gui/\(getuid())/\(c.value)"], timeout: 8).code == 0
        case "xcode-clt":
            return Shell.run("/usr/bin/xcode-select", ["-p"], timeout: 8).code == 0
        default:
            return false
        }
    }
}

// MARK: - Store additions

extension JobStore {
    static var setupPath: String { dataDirectory + "/setup.json" }

    func loadSetup() {
        guard let data = FileManager.default.contents(atPath: Self.setupPath),
              let items = try? JSONDecoder().decode([SetupItem].self, from: data) else {
            setupItems = []
            return
        }
        setupItems = items
        checkSetup()
    }

    func checkSetup() {
        let items = setupItems
        Task.detached(priority: .utility) {
            var result: [String: SetupStatus] = [:]
            for i in items { result[i.id] = SetupChecker.check(i.check) ? .ok : .missing }
            let final = result
            await MainActor.run { self.setupStatus = final }
        }
    }

    func status(of item: SetupItem) -> SetupStatus { setupStatus[item.id] ?? .unknown }

    var missingRequiredCount: Int {
        setupItems.filter { !$0.isOptional && status(of: $0) == .missing }.count
    }

    var missingCount: Int { setupItems.filter { status(of: $0) == .missing }.count }

    func fix(_ item: SetupItem) {
        guard let f = item.fix, setupBusy == nil else { return }
        switch f.type {
        case "url":
            if let u = URL(string: f.value) { NSWorkspace.shared.open(u) }
            setupOutput = "Opened \(f.value). Install it, then press Check again."
        case "note":
            setupOutput = f.value
        case "terminal":
            openInTerminal(f.value)
            setupOutput = "Opened Terminal to run:\n\(f.value)\n\nFinish there (it may ask for your password), then press Check again."
        case "brew":
            guard SetupChecker.check(SetupCheck(type: "command", value: "brew")) else {
                setupOutput = "Homebrew is not installed yet. Fix “Homebrew” first."
                return
            }
            runSetup("brew install \(f.value)", item: item)
        case "script":
            let parts = f.value.split(separator: " ").map(String.init)
            guard let first = parts.first else { return }
            let path = SetupChecker.resolve(first)
            guard FileManager.default.fileExists(atPath: path) else {
                setupOutput = "Script not found on this Mac: \(path)\nIs iCloud finished syncing ~/Documents/root?"
                return
            }
            let quoted = ([path] + parts.dropFirst()).map { "'\($0)'" }.joined(separator: " ")
            runSetup("/bin/bash \(quoted)", item: item)
        default:
            setupOutput = "Don't know how to fix items of type “\(f.type)”."
        }
    }

    private func openInTerminal(_ command: String) {
        let file = NSTemporaryDirectory() + "backstage-setup-\(Int(Date().timeIntervalSince1970)).command"
        let body = "#!/bin/bash\n\(command)\necho\necho 'Done. You can close this window and press Check again in Backstage.'\n"
        try? body.write(toFile: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file)
        NSWorkspace.shared.open(URL(fileURLWithPath: file))
    }

    private func runSetup(_ command: String, item: SetupItem) {
        setupBusy = item.id
        setupOutput = "$ \(command)\n\n"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", command]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = SetupChecker.runPath
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            let chunk = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self.setupOutput += chunk }
        }
        p.terminationHandler = { proc in
            Task { @MainActor in
                pipe.fileHandleForReading.readabilityHandler = nil
                self.setupOutput += "\n[exit \(proc.terminationStatus)]\n"
                self.setupBusy = nil
                self.checkSetup()
                self.refresh()
            }
        }
        do { try p.run() } catch {
            setupOutput += "Failed to start: \(error)\n"
            setupBusy = nil
        }
    }

    // MARK: start at login

    var startsAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setStartsAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            setupOutput = on ? "Backstage will now start at login." : "Backstage will no longer start at login."
        } catch {
            setupOutput = "Could not change the login item: \(error.localizedDescription)\n"
                + "Backstage must be run from ~/Applications or /Applications. You can also add it in System Settings > General > Login Items."
        }
        objectWillChange.send()
    }
}
