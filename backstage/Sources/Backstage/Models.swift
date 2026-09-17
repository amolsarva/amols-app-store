import Foundation
import SwiftUI

enum JobSource: String, CaseIterable, Codable {
    case userAgent = "My LaunchAgents"
    case dormantPlist = "Plists not installed"
    case openclaw = "OpenClaw cron"
    case claudeScheduled = "Claude scheduled tasks"
    case crontab = "crontab"
    case globalAgent = "Global LaunchAgents"
    case daemon = "LaunchDaemons"

    var isLaunchd: Bool { self == .userAgent || self == .globalAgent || self == .daemon }

    var launchctlDomain: String? {
        switch self {
        case .userAgent, .globalAgent: return "gui/\(getuid())"
        case .daemon: return "system"
        default: return nil
        }
    }
}

enum Health: Int, Comparable {
    case ok = 0, info = 1, warning = 2, broken = 3

    static func < (a: Health, b: Health) -> Bool { a.rawValue < b.rawValue }

    var color: Color {
        switch self {
        case .ok: return .green
        case .info: return .blue
        case .warning: return .orange
        case .broken: return .red
        }
    }

    var word: String {
        switch self {
        case .ok: return "Healthy"
        case .info: return "Note"
        case .warning: return "Needs attention"
        case .broken: return "Broken"
        }
    }

    var symbol: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .broken: return "xmark.octagon.fill"
        }
    }
}

struct Issue: Identifiable, Hashable {
    let id = UUID()
    let severity: Health
    let text: String
    var fix: String? = nil
}

struct LogFile: Hashable {
    let kind: String
    let path: String
}

struct Job: Identifiable, Hashable {
    var id: String { source.rawValue + "|" + label }
    var label: String
    var displayName: String
    var source: JobSource
    var plistPath: String?
    var program: [String] = []
    var schedule: String = "—"
    var logs: [LogFile] = []
    var summary: String = ""
    var loaded: Bool? = nil
    var running: Bool = false
    var pid: Int? = nil
    var lastExit: String? = nil
    var runs: Int? = nil
    var issues: [Issue] = []
    var lastActivity: Date? = nil
    var isVendor: Bool = false
    var rawPlist: String = ""

    var health: Health { issues.map(\.severity).max() ?? .ok }

    var statusLine: String {
        if source.isLaunchd {
            if loaded == false { return "not loaded" }
            if running { return pid.map { "running (pid \($0))" } ?? "running" }
            if let e = lastExit { return "idle · last exit \(e)" }
            return "loaded"
        }
        return source.rawValue
    }
}

/// Human-written notes about jobs. Stored as JSON next to the app source so AIs can read and update it too.
struct JobNote: Codable, Hashable {
    var whatItDoes: String = ""
    var notes: String = ""
}
