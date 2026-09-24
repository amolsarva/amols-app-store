import Foundation

struct LightMood: Identifiable {
    let id: String
    let name: String
    let detail: String
    let symbol: String
    let hex: String
    static let all: [LightMood] = [
        .init(id:"edison", name:"Edison", detail:"Honeyed filament glow", symbol:"lightbulb.fill", hex:"FF9B4300"),
        .init(id:"sunset", name:"Sunset", detail:"Last light on the horizon", symbol:"sun.horizon.fill", hex:"FF780000"),
        .init(id:"candle", name:"Candle", detail:"Deep amber, intimate", symbol:"flame.fill", hex:"FF380000"),
        .init(id:"reading", name:"Reading room", detail:"Warm parchment white", symbol:"book.closed.fill", hex:"FFD6A000"),
        .init(id:"lantern", name:"Paper lantern", detail:"Soft apricot light", symbol:"lamp.desk.fill", hex:"FFBE8500"),
        .init(id:"rose", name:"Rose quartz", detail:"Muted blush and rose", symbol:"sparkle", hex:"FF9BB500"),
        .init(id:"moon", name:"Moonlight", detail:"A silvery blue wash", symbol:"moon.fill", hex:"B0CDFF00"),
        .init(id:"lagoon", name:"Lagoon", detail:"Quiet blue-green water", symbol:"water.waves", hex:"50C6B800"),
        .init(id:"velvet", name:"Velvet", detail:"Smoky violet", symbol:"moon.stars.fill", hex:"AB76DD00"),
        .init(id:"morning", name:"Morning", detail:"Fresh golden warmth", symbol:"sunrise.fill", hex:"FFBB7000"),
        .init(id:"daylight", name:"Daylight", detail:"Neutral, luminous white", symbol:"sun.max.fill", hex:"FFF4E500"),
        .init(id:"white", name:"Pure white", detail:"Dedicated white LEDs", symbol:"circle.fill", hex:"000000FF")
    ]
}

struct LightComposition: Identifiable, Equatable {
    let id: String
    let name: String
    let detail: String
    let colors: [String]
    static let all: [LightComposition] = [
        .init(id:"ember", name:"Ember", detail:"Burnished gold → copper → embers", colors:["FF962D00","FF702000","FF491300","FF652000","FFAC4800","FF7F2500"]),
        .init(id:"blue-hour", name:"Blue Hour", detail:"Dusty blue → lavender → twilight", colors:["729EFF00","9B91E800","BD95D600","878CDB00"]),
        .init(id:"aurora", name:"Aurora", detail:"Sea glass → jade → soft violet", colors:["58BEAE00","73C89700","6CAAC800","A883CF00","789CBF00"]),
        .init(id:"rothko", name:"Color Field", detail:"Oxblood → rust → luminous apricot", colors:["FF3E4200","FF604000","FF944C00","FFC08000","FF784600"]),
        .init(id:"tidal", name:"Tidal", detail:"Deep ocean → turquoise → moonlit water", colors:["477FC600","489FBC00","64BCBC00","9EBAD800","668CBB00"]),
        .init(id:"desert", name:"Desert dusk", detail:"Sandstone → terracotta → dusty rose", colors:["FFCA9000","FFAA7300","EF816F00","D98BAD00","EAA39100"])
    ]
    func color(at index: Int) -> String { colors[((index % colors.count) + colors.count) % colors.count] }
}

struct BulbProfile: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var host: String
    var mac: String
    var hardware: String
    var channels: Int
    var timeZone: String
    /// The first ("home") bulb. Nothing device-specific is compiled in: run.sh loads it from the
    /// Mac-only local-bulb.json into these settings, or the app pairs a bulb on first use.
    static var original: BulbProfile {
        let d = UserDefaults.standard
        return BulbProfile(id: UUID(uuidString:"F3B9DE00-0000-4000-8000-000000000001")!,
                           name: d.string(forKey:"homeBulbName") ?? "My bulb",
                           host: d.string(forKey:"bulbHost") ?? "",
                           mac: d.string(forKey:"homeBulbMAC") ?? "",
                           hardware:"ESP8266EX", channels:4,
                           timeZone: d.string(forKey:"bulbTimeZone") ?? TimeZone.current.identifier)
    }
    static func compatibleStatus(_ status: [String: Any], expectedMAC: String?) throws -> (String, String, Int) {
        guard let net = status["StatusNET"] as? [String: Any], let mac = net["Mac"] as? String,
              mac.range(of: "^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$", options: .regularExpression) != nil,
              let fw = status["StatusFWR"] as? [String: Any], let hardware = fw["Hardware"] as? String,
              let version = fw["Version"] as? String, !version.isEmpty,
              let state = status["StatusSTS"] as? [String: Any], state["Dimmer"] is NSNumber,
              let channels = state["Channel"] as? [Int], channels.count >= 3,
              state["Color"] is String else {
            throw BulbError(message:"This device does not expose compatible Tasmota RGB lighting controls. Join its Wi-Fi first and finish its model-specific Tasmota setup.")
        }
        if let expectedMAC, !expectedMAC.isEmpty, mac.uppercased() != expectedMAC.uppercased() {
            throw BulbError(message:"A different bulb is answering at this address. No commands were sent. Update this bulb’s address or add the new bulb separately.")
        }
        return (mac.uppercased(), hardware, channels.count)
    }
}

enum BulbLibrary {
    static func load(_ defaults: UserDefaults = .standard) -> [BulbProfile] {
        if let data = defaults.data(forKey:"bulbProfiles.v2"),
           let saved = try? JSONDecoder().decode([BulbProfile].self, from:data), !saved.isEmpty { return saved }
        var original = BulbProfile.original
        original.host = defaults.string(forKey:"bulbHost") ?? original.host
        original.timeZone = defaults.string(forKey:"bulbTimeZone") ?? original.timeZone
        return [original]
    }
    static func save(_ profiles:[BulbProfile], selected:UUID, defaults:UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(profiles) { defaults.set(data, forKey:"bulbProfiles.v2") }
        defaults.set(selected.uuidString, forKey:"selectedBulb.v2")
    }
}
