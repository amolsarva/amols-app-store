import AppKit
import Foundation

/// Keeps Backstage current. Two sources, checked in order:
///  1. Local: the source folder in iCloud (`root/mac-scripts/backstage`). If any source file is newer than
///     what this app was built from, `build.sh` is run and the app relaunches.
///  2. Published: `latest.json` next to the dmg on amolsarva.com/downloads/backstage/ (put there by
///     mac-scripts/supporting-files/publish/release.sh; NOT under /scripts, which is the store page). If it names a newer build,
///     the dmg is downloaded, verified against its sha256, copied to ~/Applications and relaunched.
@MainActor
final class Updater: ObservableObject {
    enum Update {
        case local(newest: Date)
        case published(build: Int, version: String, dmg: URL, sha256: String?)

        var description: String {
            switch self {
            case .local(let d): return "newer source (\(d.formatted(date: .abbreviated, time: .shortened)))"
            case .published(_, let v, _, _): return "version \(v)"
            }
        }
    }

    static let manifestURL = URL(string: "https://amolsarva.com/downloads/backstage/latest.json")!
    static let interval: TimeInterval = 4 * 3600

    @Published var available: Update?
    @Published var status = ""
    /// Set when an update attempt failed, so the bar can show `status` as an error rather than a grey aside.
    @Published var failed = false
    @Published var busy = false
    @Published var autoCheck: Bool = UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoCheck, forKey: "autoUpdate") }
    }

    private var timer: Timer?

    /// Build number = seconds since epoch of the newest source file when build.sh ran.
    static var builtStamp: Int { Int(Bundle.main.object(forInfoDictionaryKey: "BackstageBuild") as? String ?? "") ?? 0 }
    nonisolated static var sourceDir: String { Scanner.documents + "/root/mac-scripts/backstage" }

    init() {
        // First check shortly after launch, then every few hours while running.
        Task { try? await Task.sleep(nanoseconds: 20_000_000_000); self.check(manual: false) }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check(manual: false) }
        }
    }

    nonisolated static func newestSourceStamp() -> Int {
        let fm = FileManager.default
        var newest = 0
        var files = [sourceDir + "/Package.swift", sourceDir + "/build.sh"]
        files += ((try? fm.contentsOfDirectory(atPath: sourceDir + "/Sources/Backstage")) ?? [])
            .filter { $0.hasSuffix(".swift") }.map { sourceDir + "/Sources/Backstage/" + $0 }
        for f in files {
            if let d = (try? fm.attributesOfItem(atPath: f))?[.modificationDate] as? Date {
                newest = max(newest, Int(d.timeIntervalSince1970))
            }
        }
        return newest
    }

    func check(manual: Bool) {
        guard !busy, manual || autoCheck else { return }
        // Dev builds (`swift run`) have no stamp; nothing to compare against.
        let built = Self.builtStamp
        Task {
            if manual { status = "Checking…"; failed = false }
            // 1. local source folder
            let src = await Task.detached { Self.newestSourceStamp() }.value
            if built > 0, src > built {
                available = .local(newest: Date(timeIntervalSince1970: TimeInterval(src)))
                status = ""
                return
            }
            // 2. published manifest
            do {
                var req = URLRequest(url: Self.manifestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
                req.setValue("Backstage/\(built)", forHTTPHeaderField: "User-Agent")
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode == 200,
                      let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let build = j["build"] as? Int,
                      let urlStr = j["dmg"] as? String, let url = URL(string: urlStr, relativeTo: Self.manifestURL)?.absoluteURL,
                      url.scheme == "https", url.host == Self.manifestURL.host else {
                    if manual { status = src > 0 ? "Up to date (nothing published yet)." : "Up to date." }
                    return
                }
                if build > built {
                    available = .published(build: build, version: j["version"] as? String ?? "\(build)",
                                           dmg: url, sha256: (j["sha256"] as? String)?.lowercased())
                    status = ""
                } else if manual { status = "Up to date." }
            } catch {
                if manual { status = "Up to date locally; couldn't reach amolsarva.com." }
            }
        }
    }

    func install(_ u: Update) {
        guard !busy else { return }
        busy = true
        failed = false
        status = "Updating…"
        Task {
            do {
                switch u {
                case .local: try await Self.rebuildFromSource()
                case .published(_, _, let dmg, let sha): try await Self.installDMG(dmg, sha256: sha)
                }
                status = "Relaunching…"
                Self.relaunch()
            } catch {
                busy = false
                failed = true
                status = error.localizedDescription
            }
        }
    }

    // MARK: apply

    struct UpdateError: LocalizedError { let errorDescription: String? }

    @discardableResult
    static func sh(_ cmd: String) async throws -> String {
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-lc", cmd]
            let pipe = Pipe()
            p.standardOutput = pipe; p.standardError = pipe
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let out = String(decoding: data, as: UTF8.self)
            guard p.terminationStatus == 0 else {
                throw UpdateError(errorDescription: "exit \(p.terminationStatus): " + out.split(separator: "\n").suffix(3).joined(separator: " | "))
            }
            return out
        }.value
    }

    static func rebuildFromSource() async throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/swift") else {
            throw UpdateError(errorDescription: "Swift isn't installed (run xcode-select --install).")
        }
        if let blocked = appOwnershipProblem() { throw UpdateError(errorDescription: blocked) }
        try await sh("cd '\(sourceDir)' && ./build.sh")
    }

    /// Opening the .pkg installer leaves ~/Applications/Backstage.app owned by root, and then build.sh
    /// can't delete it to put the new one in place. Say so up front instead of after a minute of compiling.
    static func appOwnershipProblem() -> String? {
        let app = Scanner.home + "/Applications/Backstage.app"
        guard let owner = (try? FileManager.default.attributesOfItem(atPath: app))?[.ownerAccountID] as? NSNumber,
              owner.uint32Value != getuid() else { return nil }
        let name = (try? FileManager.default.attributesOfItem(atPath: app))?[.ownerAccountName] as? String ?? "another user"
        return """
        Backstage.app is owned by \(name), not you, so the update can't replace it.         Run this once in Terminal, then update again:
        sudo chown -R "$(whoami)":staff ~/Applications/Backstage.app
        """
    }

    static func installDMG(_ url: URL, sha256: String?) async throws {
        let (tmp, resp) = try await URLSession.shared.download(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError(errorDescription: "download failed") }
        let dmg = NSTemporaryDirectory() + "Backstage-update.dmg"
        try? FileManager.default.removeItem(atPath: dmg)
        try FileManager.default.moveItem(at: tmp, to: URL(fileURLWithPath: dmg))
        if let want = sha256 {
            let got = try await sh("shasum -a 256 '\(dmg)' | cut -d' ' -f1").trimmingCharacters(in: .whitespacesAndNewlines)
            guard got == want else { throw UpdateError(errorDescription: "checksum mismatch; not installing") }
        }
        let mount = NSTemporaryDirectory() + "backstage-mount"
        try await sh("mkdir -p '\(mount)' && hdiutil attach -nobrowse -readonly -mountpoint '\(mount)' '\(dmg)' >/dev/null")
        do {
            try await sh("mkdir -p ~/Applications && rm -rf ~/Applications/Backstage.app && cp -R '\(mount)/Backstage.app' ~/Applications/ && xattr -dr com.apple.quarantine ~/Applications/Backstage.app")
        } catch {
            _ = try? await sh("hdiutil detach '\(mount)' -force")
            throw error
        }
        _ = try? await sh("hdiutil detach '\(mount)' -force; rm -f '\(dmg)'")
    }

    static func relaunch() {
        let app = Scanner.home + "/Applications/Backstage.app"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "sleep 1; open '\(app)'"]
        try? p.run()
        NSApp.terminate(nil)
    }
}
