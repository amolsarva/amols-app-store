import SwiftUI
import AppKit

@MainActor
final class LightModel: ObservableObject {
    @Published var host = UserDefaults.standard.string(forKey: "bulbHost") ?? ""
    @Published var password = ""
    @Published var online = false
    @Published var busy = false
    @Published var power = false
    @Published var brightness = 75.0
    @Published var temperature = 3000.0
    @Published var white = 0.0
    @Published var color = Color.orange
    @Published var colorHex = "FF7800"
    @Published var automatic = false
    @Published var message = "Connect to your light to read its current state."
    @Published var log = ""
    @Published var deviceTime = "—"
    @Published var signal = "—"
    @Published var version = "—"
    @Published var uptime = "—"
    @Published var backupPath = ""
    @Published var timeZone = UserDefaults.standard.string(forKey: "bulbTimeZone") ?? TimeZone.current.identifier
    @Published var programInstalled = false
    @Published var installConfirmation = false
    @Published var restartConfirmation = false
    @Published var profiles: [BulbProfile] = []
    @Published var selectedID = BulbProfile.original.id
    @Published var draftName = ""
    @Published var draftHost = ""
    @Published var draftPassword = ""
    @Published var activeComposition: LightComposition?
    @Published var artStep = 0
    @Published var artInterval = 90.0
    @Published var selectedTab = "light"
    @Published var chimeEnabled = false
    @Published var chiming = false
    @Published var chimeMessage = "Hourly chime is off. Blink now works without enabling it."
    private var chimeTask: Task<Void, Never>?
    private var chimeSchedule = ChimeSchedule(now: Date(), timeZone: TimeZone.current.identifier)
    private var artTask: Task<Void, Never>?
    private var artGeneration = UUID()
    private var passwords: [UUID: String] = [:]
    private var validatedHost: String?

    init() {
        profiles = BulbLibrary.load()
        let saved = UserDefaults.standard.string(forKey: "selectedBulb.v2").flatMap(UUID.init(uuidString:))
        selectedID = profiles.first(where: { $0.id == saved })?.id ?? profiles[0].id
        host = selectedProfile.host
        timeZone = selectedProfile.timeZone
        loadChimePreference()
    }
    func loadChimePreference() {
        chimeEnabled = UserDefaults.standard.bool(forKey: LightChime.key(selectedID))
        chimeSchedule = ChimeSchedule(now: Date(), timeZone: selectedProfile.timeZone)
        chimeMessage = chimeEnabled ? "Armed for the next hour on the selected bulb." : "Hourly chime is off. Blink now works without enabling it."
    }
    func setChimeEnabled(_ enabled: Bool) {
        chimeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: LightChime.key(selectedID))
        loadChimePreference()
    }
    func startChimeClock() {
        guard chimeTask == nil else { return }
        chimeTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                self?.checkChimeClock()
            }
        }
    }
    func checkChimeClock(now: Date = Date()) {
        if let count = chimeSchedule.due(now: now, timeZone: selectedProfile.timeZone,
                                         available: chimeEnabled && !busy) {
            blinkNow(count: count)
        }
    }
    func blinkNow(count: Int? = nil) {
        guard !busy else { return }
        let strikes = count ?? LightChime.count(at: Date(), timeZone: selectedProfile.timeZone)
        chiming = true
        chimeMessage = "Chiming \(strikes) \(strikes == 1 ? "blink" : "blinks")…"
        perform(chimeMessage) { c in
            defer { self.chiming = false }
            do {
                self.readState(try await c.chime(count: strikes))
                self.chimeMessage = "Finished \(strikes) \(strikes == 1 ? "blink" : "blinks") · previous light state preserved"
                self.message = self.chimeMessage
            } catch {
                self.chimeMessage = "Chime could not be confirmed: \(error.localizedDescription)"
                throw error
            }
        }
    }
    var selectedProfile: BulbProfile { profiles.first(where: { $0.id == selectedID }) ?? BulbProfile.original }
    var supportsWhite: Bool { selectedProfile.channels >= 4 }
    /// Daylight rules replace the bulb's rule set, so they're only offered for a bulb you've marked as tested.
    var canInstallDaylight: Bool {
        guard let verified = UserDefaults.standard.string(forKey: "daylightVerifiedMAC"), !verified.isEmpty else { return false }
        return selectedProfile.mac.uppercased() == verified.uppercased() && selectedProfile.hardware == "ESP8266EX"
    }
    func client() throws -> BulbClient { try BulbClient(host: host, password: password, expectedMAC: selectedProfile.mac) }
    func saveLibrary() { BulbLibrary.save(profiles, selected: selectedID) }
    func selectBulb(_ id: UUID) {
        guard !busy, let p = profiles.first(where: { $0.id == id }), selectedID != id else { return }
        stopComposition()
        passwords[selectedID] = password
        selectedID = id; host = p.host; timeZone = p.timeZone
        loadChimePreference()
        password = passwords[id] ?? ""
        online = false; automatic = false; programInstalled = false
        power = false; deviceTime = "—"; version = "—"; signal = "—"; uptime = "—"; backupPath = ""
        saveLibrary(); connect()
    }
    func addBulb() {
        guard !busy else { return }
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = draftHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = draftPassword
        guard !name.isEmpty else { message = "Give the bulb a name, such as Desk or Bedroom."; return }
        stopComposition(); busy = true; message = "Checking the new bulb without changing its settings…"
        Task {
            do {
                let candidate = try BulbClient(host: address, password: secret, expectedMAC: nil)
                let status = try await candidate.identify()
                let (mac, hardware, channels) = try BulbProfile.compatibleStatus(status, expectedMAC: nil)
                let existing = profiles.first(where: { $0.mac == mac })
                let profile = BulbProfile(id: existing?.id ?? UUID(), name: name, host: address, mac: mac,
                                          hardware: hardware, channels: channels, timeZone: existing?.timeZone ?? timeZone)
                if let index = profiles.firstIndex(where: { $0.mac == mac }) { profiles[index] = profile }
                else { profiles.append(profile) }
                passwords[selectedID] = password
                selectedID = profile.id; host = profile.host; password = secret; timeZone = profile.timeZone
                loadChimePreference()
                passwords[profile.id] = secret
                draftName = ""; draftHost = ""; draftPassword = ""
                saveLibrary(); busy = false; selectedTab = "light"; connect()
            } catch {
                message = "Bulb not added: \(error.localizedDescription)"; record(message); busy = false
            }
        }
    }
    func stopComposition() {
        artGeneration = UUID(); artTask?.cancel(); artTask = nil
        if activeComposition != nil { message = "Composition stopped · holding the last color" }
        activeComposition = nil; artStep = 0
    }
    func startComposition(_ composition: LightComposition) {
        guard !busy, online else { return }
        stopComposition()
        perform("Starting \(composition.name)") { [self] c in
            let state = try await c.command("State")
            guard state["POWER"] as? String == "ON" else {
                self.readState(state); self.message = "Turn the light on before starting a composition."; return
            }
            if self.programInstalled { _ = try await c.command("Mem2 0"); self.automatic = false }
            for command in ["SetOption20 1", "Scheme 0", "Fade 1", "Speed2 40", "Color2 \(composition.color(at: 0))"] {
                let result = try await c.command(command)
                if command.hasPrefix("Color2 ") { self.readState(result) }
            }
            self.activeComposition = composition; self.artStep = 0
            self.message = "\(composition.name) · slow transitions · Mac must stay awake"
            let generation = self.artGeneration
            self.artTask = Task { [weak self] in
                guard let self else { return }
                var step = 1
                var ownsBusy = false
                while !Task.isCancelled && self.artGeneration == generation {
                    do {
                        try await Task.sleep(nanoseconds: UInt64(self.artInterval * 1_000_000_000))
                        while self.busy { try await Task.sleep(nanoseconds: 500_000_000) }
                        try Task.checkCancellation()
                        guard self.artGeneration == generation else { return }
                        self.busy = true; ownsBusy = true
                        _ = try await c.identify()
                        let state = try await c.command("State")
                        try Task.checkCancellation()
                        if state["POWER"] as? String != "ON" {
                            self.readState(state); self.stopComposition(); self.busy = false; ownsBusy = false
                            self.message = "Composition stopped because the bulb is off."; return
                        }
                        let result = try await c.command("Color2 \(composition.color(at: step))")
                        try Task.checkCancellation()
                        self.readState(result); self.artStep = step % composition.colors.count
                        self.message = "\(composition.name) · color \(self.artStep + 1) of \(composition.colors.count)"
                        step += 1; self.busy = false; ownsBusy = false
                    } catch is CancellationError {
                        if ownsBusy { self.busy = false }; return
                    } catch {
                        self.busy = false; self.online = false; self.stopComposition()
                        self.message = "Composition stopped: \(error.localizedDescription)"; self.record(self.message); return
                    }
                }
            }
        }
    }
    func record(_ text: String) {
        log = "\(Date().formatted(date: .omitted, time: .standard))  \(text)\n" + log
        log = String(log.prefix(18000))
    }
    func perform(_ title: String, action: @escaping (BulbClient) async throws -> Void) {
        guard !busy else { return }
        busy = true; message = title
        Task {
            do {
                let c = try client()
                _ = try await c.identify(); validatedHost = host
                try await action(c)
                online = true
                record(title + " — confirmed")
            } catch {
                if chiming { chiming = false; chimeMessage = "Chime could not be confirmed: \(error.localizedDescription)" }
                online = false
                message = error.localizedDescription + " Reconnect to verify the device before retrying."
                record(message)
            }
            busy = false
        }
    }
    func readState(_ data: [String: Any]) {
        power = (data["POWER"] as? String) == "ON"
        brightness = (data["Dimmer"] as? NSNumber)?.doubleValue ?? brightness
        white = (data["White"] as? NSNumber)?.doubleValue ?? white
        colorHex = data["Color"] as? String ?? colorHex
        uptime = data["Uptime"] as? String ?? uptime
        if let wifi = data["Wifi"] as? [String: Any], let dbm = wifi["Signal"] { signal = "\(dbm) dBm" }
        if let time = data["Time"] as? String { deviceTime = time }
    }
    func connect() {
        guard !busy else { return }
        stopComposition()
        validatedHost = nil
        perform("Reading the light") { c in
            let status = try await c.identify()
            self.validatedHost = self.host
            self.readState(status["StatusSTS"] as? [String: Any] ?? [:])
            self.version = (status["StatusFWR"] as? [String: Any])?["Version"] as? String ?? "—"
            let r = try? await c.command("Rule3")
            self.programInstalled = (r?["Rule3"] as? [String: Any])?["Rules"] as? String == DaylightProgram.rules[2]
            if self.programInstalled {
                for i in 1...2 {
                    let existing = try await c.command("Rule\(i)")
                    self.programInstalled = self.programInstalled && ((existing["Rule\(i)"] as? [String: Any])?["Rules"] as? String == DaylightProgram.rules[i-1])
                }
            }
            let mem = self.programInstalled ? try await c.command("Mem2") : [:]
            self.automatic = self.programInstalled && (mem["Mem2"] as? String == "1")
            UserDefaults.standard.set(self.host, forKey: "bulbHost")
            if let index = self.profiles.firstIndex(where: { $0.id == self.selectedID }) {
                self.profiles[index].host = self.host
                self.passwords[self.selectedID] = self.password
                self.saveLibrary()
            }
            self.message = "Connected · settings read from the bulb"
        }
    }
    func send(_ command: String, manual: Bool = false) {
        guard !busy else { return }
        if manual || command == "Power Off" || command.hasPrefix("Restart") || command == "Event tick" { stopComposition() }
        perform("Applying \(command)") { c in
            if manual && self.programInstalled {
                _ = try await c.command("Mem2 0")
                self.automatic = false
            }
            if manual {
                _ = try await c.command("SetOption20 1")
                _ = try await c.command("Speed2 !"); _ = try await c.command("Scheme 0")
            }
            let result = try await c.command(command)
            self.record(String(describing: result))
            self.readState(try await c.command("State"))
            self.message = "Updated · \(command)"
        }
    }
    func setColor(_ hex: String) { send("Color2 \(hex)", manual: true) }
    func pickColor() {
        guard let c = NSColor(color).usingColorSpace(.deviceRGB) else { return }
        setColor(String(format: "%02X%02X%02X00", Int(c.redComponent*255), Int(c.greenComponent*255), Int(c.blueComponent*255)))
    }
    func setAutomatic(_ enabled: Bool) {
        guard !busy else { return }
        stopComposition()
        guard programInstalled else { message = "Install the daylight program from the Daylight tab first."; return }
        perform(enabled ? "Resuming daylight" : "Pausing daylight") { c in
            _ = try await c.command("Mem2 \(enabled ? 1 : 0)")
            if enabled { _ = try await c.command("Event tick") }
            self.automatic = enabled
            self.message = enabled ? "Daylight enabled on the bulb; the Mac can sleep." : "Manual control; daylight paused."
        }
    }
    func backup() {
        perform("Saving recovery backup") { c in
            self.backupPath = try await c.backup().path
            self.message = "Recovery backup saved in your private vault."
        }
    }
    func timeCommands() -> [String] {
        switch timeZone {
        case "Europe/Paris": return ["TimeSTD 0,0,10,1,3,60", "TimeDST 0,0,3,1,2,120", "Timezone 99"]
        case "Europe/London": return ["TimeSTD 0,0,10,1,2,0", "TimeDST 0,0,3,1,1,60", "Timezone 99"]
        case "America/Los_Angeles": return ["TimeSTD 0,1,11,1,2,-480", "TimeDST 0,2,3,1,2,-420", "Timezone 99"]
        case "UTC": return ["Timezone 0"]
        default: return ["TimeSTD 0,1,11,1,2,-300", "TimeDST 0,2,3,1,2,-240", "Timezone 99"]
        }
    }
    func configureClock() {
        perform("Setting the bulb’s clock") { c in
            for command in self.timeCommands() { _ = try await c.command(command) }
            _ = try await c.command("Time \(Int(Date().timeIntervalSince1970))")
            _ = try await c.command("Time 0")
            UserDefaults.standard.set(self.timeZone, forKey: "bulbTimeZone")
            if let index = self.profiles.firstIndex(where: { $0.id == self.selectedID }) {
                self.profiles[index].timeZone = self.timeZone; self.saveLibrary()
            }
            self.message = "Timezone saved; time synchronized from this Mac. NTP maintains it independently."
        }
    }
    func installProgram() {
        guard !busy, canInstallDaylight else { message = "Daylight rules are only offered for a bulb listed as daylightVerifiedMAC in local-bulb.json. Other bulbs keep their own rules."; return }
        stopComposition()
        perform("Backing up and installing the daylight program") { c in
            self.backupPath = try await c.backup().path
            for i in 1...3 {
                let r = try await c.command("Rule\(i)")
                let previous = (r["Rule\(i)"] as? [String: Any])?["Rules"] as? String ?? ""
                let ours = previous.isEmpty || previous == DaylightProgram.rules[i-1] || previous == DaylightProgram.legacyRules[i-1] ||
                    (i == 1 && previous == "ON Power1#Boot DO Color2 FF780000 ENDON ON Power1#State=1 DO Color2 FF780000 ENDON")
                guard ours else { throw BulbError(message: "Rule\(i) contains another automation. Backup saved; installation stopped to preserve it.") }
            }
            // Disable before replacement; never enable a partially installed program.
            for i in 1...3 { _ = try await c.command("Rule\(i) 0") }
            _ = try await c.command("Mem2 0")
            do {
                for i in 1...3 {
                    _ = try await c.command("Rule\(i) \(DaylightProgram.rules[i-1])")
                    let r = try await c.command("Rule\(i)")
                    guard let rule = r["Rule\(i)"] as? [String: Any],
                          rule["Length"] as? Int == DaylightProgram.rules[i-1].utf8.count,
                          rule["Rules"] as? String == DaylightProgram.rules[i-1] else {
                        throw BulbError(message: "Rule\(i) failed length verification. Program remains disabled; restore the recovery backup if necessary.")
                    }
                }
                for command in ["SetOption20 1", "SetOption65 1", "Fade 1", "Speed 10", "PowerOnState 1", "Mem1 720", "Mem2 0", "Mem3 0", "Mem4 0", "Var1 1", "Var2 720", "Rule1 1", "Rule2 1", "Rule3 1", "RuleTimer1 3600"] {
                    _ = try await c.command(command)
                }
                for command in self.timeCommands() { _ = try await c.command(command) }
                _ = try await c.command("Time \(Int(Date().timeIntervalSince1970))")
                _ = try await c.command("Time 0")
                _ = try await c.command("Mem2 0")
                _ = try await c.command("Color2 \(DaylightProgram.sunset)")
                self.programInstalled = true; self.automatic = false
                self.message = "Native switch modes installed. Power-on is Edison warm; triple-cycle enables daylight."
            } catch {
                // Never report success after a partial installation. Avoid rollback writes on a lost connection.
                throw BulbError(message: "Installation incomplete. \(error.localizedDescription) Recovery backup: \(self.backupPath)")
            }
        }
    }
}
