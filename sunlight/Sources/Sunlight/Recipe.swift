import Foundation

/// A recipe is the bulb's daylight color schedule: the Rule3 statements that pick a color
/// for the current minute of the day. Rule1-2 (modes, clock, chime) stay as installed.
struct DaylightStop: Codable, Identifiable, Equatable {
    var id = UUID()
    var minute: Int
    var hex: String
    enum CodingKeys: String, CodingKey { case minute, hex }
    init(minute: Int, hex: String, id: UUID = UUID()) {
        self.id = id; self.minute = minute; self.hex = hex
    }
    var label: String { String(format: "%02d:%02d", minute / 60, minute % 60) }
}

struct LightRecipe: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var stops: [DaylightStop]
    enum CodingKeys: String, CodingKey { case id, name, stops }
}

enum RecipeCompiler {
    /// Tasmota keeps each rule set in a 511-byte buffer; a longer recipe is refused before any write.
    static let limit = 511
    static let tail = [
        "ON Event#b DO Backlog Fade 0;BlinkTime 7;BlinkCount 3;RuleTimer3 8;Power1 3 ENDON",
        "ON Rules#Timer=3 DO Backlog Fade 1;BlinkTime 10;BlinkCount 10 ENDON"
    ]

    static func normalized(_ stops: [DaylightStop]) throws -> [DaylightStop] {
        var sorted = stops.sorted { $0.minute < $1.minute }
        guard !sorted.isEmpty else { throw BulbError(message: "A recipe needs at least one color.") }
        guard sorted[0].minute == 0 else { throw BulbError(message: "The first color must start at 00:00 so every minute of the day has one.") }
        for stop in sorted {
            guard (0..<1440).contains(stop.minute) else { throw BulbError(message: "\(stop.label) is outside a 24-hour day.") }
            guard stop.hex.count == 8, UInt32(stop.hex, radix: 16) != nil else {
                throw BulbError(message: "\(stop.hex) is not an eight-digit RGBW value such as FFBB7000.")
            }
        }
        guard Set(sorted.map(\.minute)).count == sorted.count else {
            throw BulbError(message: "Two colors start at the same time. Give each one its own start.")
        }
        sorted = sorted.map { DaylightStop(minute: $0.minute, hex: $0.hex.uppercased(), id: $0.id) }
        return sorted
    }

    static func rule(_ stops: [DaylightStop]) throws -> String {
        let sorted = try normalized(stops)
        let statements = sorted.enumerated().map { index, stop in
            index == 0 ? "ON Event#d DO Color2 \(stop.hex) ENDON"
                       : "ON Event#d>=\(stop.minute) DO Color2 \(stop.hex) ENDON"
        }
        let text = (statements + tail).joined(separator: " ")
        guard text.utf8.count <= limit else {
            throw BulbError(message: "This recipe needs \(text.utf8.count) bytes; the bulb holds \(limit). Remove a color or two.")
        }
        return text
    }

    /// Byte cost without the validity checks, so the editor can show a live meter mid-edit.
    static func size(_ stops: [DaylightStop]) -> Int {
        let statements = stops.sorted { $0.minute < $1.minute }.enumerated().map { index, stop in
            index == 0 ? "ON Event#d DO Color2 \(stop.hex) ENDON"
                       : "ON Event#d>=\(stop.minute) DO Color2 \(stop.hex) ENDON"
        }
        return (statements + tail).joined(separator: " ").utf8.count
    }

    /// Reads back whatever daylight schedule a bulb is actually running, including one we did not write.
    static func stops(fromRule text: String) -> [DaylightStop] {
        let pattern = "ON Event#d(>=([0-9]{1,4}))? DO Color2 ([0-9A-Fa-f]{6,8}) ENDON"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let hexRange = Range(match.range(at: 3), in: text) else { return nil }
            var hex = String(text[hexRange]).uppercased()
            while hex.count < 8 { hex += "0" }
            var minute = 0
            if let minuteRange = Range(match.range(at: 2), in: text) { minute = Int(text[minuteRange]) ?? 0 }
            return DaylightStop(minute: minute, hex: hex)
        }.sorted { $0.minute < $1.minute }
    }

    static func color(_ stops: [DaylightStop], atMinute minute: Int) -> String? {
        stops.sorted { $0.minute < $1.minute }.last(where: { minute >= $0.minute })?.hex
    }
}

enum RecipeLibrary {
    static let key = "recipes.v1"
    static var installed: LightRecipe {
        LightRecipe(name: "Installed daylight", stops: RecipeCompiler.stops(fromRule: DaylightProgram.rules[2]))
    }
    static let presets: [LightRecipe] = [
        installed,
        LightRecipe(name: "Candle evening", stops: [
            .init(minute: 0, hex: "FF2A0000"), .init(minute: 360, hex: "FF780000"),
            .init(minute: 540, hex: "FFBB7000"), .init(minute: 720, hex: "FFF4E500"),
            .init(minute: 960, hex: "FFAA5000"), .init(minute: 1140, hex: "FF5A1800"),
            .init(minute: 1260, hex: "FF2A0000")]),
        LightRecipe(name: "Cool workday", stops: [
            .init(minute: 0, hex: "FF500000"), .init(minute: 420, hex: "FFD9A000"),
            .init(minute: 540, hex: "FFF4E540"), .init(minute: 1020, hex: "FFE4BE00"),
            .init(minute: 1140, hex: "FF780000"), .init(minute: 1320, hex: "FF380000")]),
        LightRecipe(name: "Polar night", stops: [
            .init(minute: 0, hex: "8090C000"), .init(minute: 480, hex: "B0CDFF00"),
            .init(minute: 780, hex: "90A8E000"), .init(minute: 1080, hex: "6070B000"),
            .init(minute: 1260, hex: "40508000")])
    ]
    static func load(_ defaults: UserDefaults = .standard) -> [LightRecipe] {
        guard let data = defaults.data(forKey: key),
              let saved = try? JSONDecoder().decode([LightRecipe].self, from: data) else { return [] }
        return saved
    }
    static func save(_ recipes: [LightRecipe], _ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(recipes) { defaults.set(data, forKey: key) }
    }
}

@MainActor
extension LightModel {
    func readRecipe() {
        perform("Reading the bulb’s recipe") { c in
            var texts = ["", "", ""], states = ["—", "—", "—"], free = "—"
            for i in 1...3 {
                let rule = (try await c.command("Rule\(i)"))["Rule\(i)"] as? [String: Any] ?? [:]
                texts[i-1] = rule["Rules"] as? String ?? ""
                states[i-1] = (rule["State"] as? String ?? "—") + " · \(rule["Length"] as? Int ?? 0) bytes"
                if i == 3, let remaining = rule["Free"] { free = "\(remaining) bytes free" }
            }
            var memory: [String] = []
            for name in ["Mem1", "Mem2", "Mem3", "Mem4", "Var1", "Var2", "Var3", "Var4"] {
                let value = (try await c.command(name))[name]
                memory.append("\(name) = \(value.map { "\($0)" } ?? "—")")
            }
            self.liveRules = texts; self.liveRuleStates = states; self.liveFree = free
            self.liveMemory = memory
            self.liveStops = RecipeCompiler.stops(fromRule: texts[2])
            self.programInstalled = texts == DaylightProgram.rules
            self.automatic = (try await c.command("Mem2"))["Mem2"] as? String == "1"
            self.recipeRead = true
            self.recipeMessage = self.liveStops.isEmpty
                ? "No daylight recipe found in Rule3. The raw rules are shown below."
                : "Read \(self.liveStops.count) colors from Rule3 · \(free)."
            self.message = self.recipeMessage
        }
    }
    func editLiveRecipe() {
        guard !liveStops.isEmpty else { recipeMessage = "Read the bulb first, or start from a saved recipe."; return }
        draftStops = liveStops
        draftRecipeName = "Copy of what’s running"
        recipeMessage = "Editing a copy of the recipe on the bulb. Nothing is written until you apply it."
    }
    func addStop() {
        let last = draftStops.map(\.minute).max() ?? 0
        guard last < 1439 else { recipeMessage = "The day is full; remove a color first."; return }
        draftStops.append(DaylightStop(minute: min(1439, last + 60), hex: draftStops.last?.hex ?? "FFBB7000"))
        draftStops.sort { $0.minute < $1.minute }
    }
    func removeStop(_ id: UUID) {
        draftStops.removeAll { $0.id == id }
    }
    func previewStop(_ hex: String) { send("Color2 \(hex)", manual: true) }
    func saveDraftRecipe() {
        do {
            let stops = try RecipeCompiler.normalized(draftStops)
            let name = draftRecipeName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { recipeMessage = "Give the recipe a name."; return }
            if let index = recipes.firstIndex(where: { $0.name == name }) {
                recipes[index].stops = stops
            } else {
                recipes.append(LightRecipe(name: name, stops: stops))
            }
            RecipeLibrary.save(recipes)
            recipeMessage = "Saved “\(name)” on this Mac. Apply it to write it to the bulb."
        } catch {
            recipeMessage = error.localizedDescription
        }
    }
    func loadRecipe(_ recipe: LightRecipe) {
        draftStops = recipe.stops.map { DaylightStop(minute: $0.minute, hex: $0.hex) }
        draftRecipeName = recipe.name
        recipeMessage = "Loaded “\(recipe.name)”. Nothing is written until you apply it."
    }
    func deleteRecipe(_ recipe: LightRecipe) {
        recipes.removeAll { $0.id == recipe.id }
        RecipeLibrary.save(recipes)
    }
    /// Writes Rule3 only: the color schedule. Rule1-2 keep the modes, clock and chime as installed.
    func applyRecipe() {
        guard canInstallDaylight else {
            recipeMessage = "Writing rules is limited to the bulb listed as daylightVerifiedMAC in local-bulb.json."; return
        }
        guard programInstalled else {
            recipeMessage = "Install the daylight program from the Daylight tab first; a recipe replaces its color schedule."; return
        }
        let text: String
        do { text = try RecipeCompiler.rule(draftStops) } catch {
            recipeMessage = error.localizedDescription; return
        }
        let stops = draftStops
        stopComposition()
        perform("Backing up and writing the recipe") { c in
            self.backupPath = try await c.backup().path
            let previous = ((try await c.command("Rule3"))["Rule3"] as? [String: Any])?["Rules"] as? String ?? ""
            guard previous == DaylightProgram.rules[2] || !RecipeCompiler.stops(fromRule: previous).isEmpty else {
                throw BulbError(message: "Rule3 holds another automation. Backup saved; nothing was written.")
            }
            _ = try await c.command("Rule3 0")
            _ = try await c.command("Rule3 \(text)")
            let written = (try await c.command("Rule3"))["Rule3"] as? [String: Any] ?? [:]
            guard written["Rules"] as? String == text, written["Length"] as? Int == text.utf8.count else {
                throw BulbError(message: "Rule3 failed verification and stays disabled. Restore the recovery backup: \(self.backupPath)")
            }
            _ = try await c.command("Rule3 1")
            if self.automatic { _ = try await c.command("Event tick") }
            self.liveRules[2] = text
            self.liveStops = stops
            self.programInstalled = self.liveRules == DaylightProgram.rules
            self.recipeMessage = "Recipe written to the bulb · \(text.utf8.count) bytes · \(stops.count) colors."
            self.message = self.recipeMessage
        }
    }
    func restoreInstalledRecipe() {
        draftStops = RecipeLibrary.installed.stops.map { DaylightStop(minute: $0.minute, hex: $0.hex) }
        draftRecipeName = "Installed daylight"
        recipeMessage = "Loaded the recipe Sunlight installs. Apply it to put the bulb back to standard."
    }
}
