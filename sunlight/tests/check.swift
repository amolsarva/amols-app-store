import Foundation
import Darwin

@main struct Checks {
    static func fixture(mac:String = "02:00:00:00:00:01", channels:[Int] = [75,30,0,0]) -> [String:Any] {
        ["StatusNET":["Mac":mac], "StatusFWR":["Hardware":"ESP8266EX","Version":"15.6.0"],
         "StatusSTS":["Color":"BF5A0000", "Dimmer":75, "Channel":channels]]
    }
    static func rejects(_ body: () throws -> Void) {
        do { try body(); fatalError("Expected rejection") } catch { }
    }
    static func require(_ condition:Bool, _ message:String) throws {
        if !condition { throw BulbError(message:message) }
    }
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        rejects { _ = try BulbProfile.compatibleStatus(fixture(mac:"AA:BB:CC:DD:EE:FF"), expectedMAC:"02:00:00:00:00:01") }
        let paired = try BulbProfile.compatibleStatus(fixture(mac:"AA:BB:CC:DD:EE:FF"), expectedMAC:nil)
        precondition(paired.0 == "AA:BB:CC:DD:EE:FF" && paired.2 == 4)
        rejects { _ = try BulbProfile.compatibleStatus(["StatusNET":["Mac":"02:00:00:00:00:01"]], expectedMAC:nil) }
        rejects { _ = try BulbProfile.compatibleStatus(fixture(channels:[100]), expectedMAC:nil) }
        rejects { _ = try BulbProfile.compatibleStatus(fixture(mac:"bad"), expectedMAC:nil) }
        print("PASS: identity pinning, compatible pairing, non-light rejection")
        precondition(LightMood.all.count == 12 && LightComposition.all.count == 6)
        precondition(Set(LightMood.all.map(\.id)).count == 12)
        for scene in LightComposition.all {
            precondition(scene.colors.count >= 4)
            precondition(scene.color(at:scene.colors.count) == scene.colors[0])
            precondition(scene.color(at:-1) == scene.colors.last)
        }
        for hex in LightMood.all.map(\.hex) + LightComposition.all.flatMap(\.colors) {
            precondition(hex.count == 8 && UInt32(hex,radix:16) != nil)
        }
        print("PASS: twelve moods, six compositions, palette validity and looping")
        let name = "SunlightTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName:name)!
        defer { defaults.removePersistentDomain(forName:name) }
        defaults.set("192.168.1.88",forKey:"bulbHost")
        let migrated = BulbLibrary.load(defaults)
        precondition(migrated[0].host == "192.168.1.88")
        var second = BulbProfile.original
        second.id=UUID(); second.name="Desk"; second.mac="AA:BB:CC:DD:EE:FF"
        BulbLibrary.save(migrated+[second], selected:second.id,defaults:defaults)
        precondition(BulbLibrary.load(defaults) == migrated+[second])
        precondition(defaults.string(forKey:"selectedBulb.v2") == second.id.uuidString)
        print("PASS: migration, multiple saved bulbs, selected bulb persistence")
        let model = LightModel()
        let original = model.selectedID
        model.busy = true
        model.selectBulb(UUID()); model.stopComposition()
        precondition(model.selectedID == original && model.busy)
        model.busy = false
        model.activeComposition = LightComposition.all[0]
        model.stopComposition()
        precondition(model.activeComposition == nil)
        print("PASS: selection busy guard and stop/hold state")
        if CommandLine.arguments.contains("--live") || CommandLine.arguments.contains("--exercise") {
            let client = try BulbClient(host:BulbProfile.original.host,expectedMAC:BulbProfile.original.mac)
            let status = try await client.identify()
            precondition((status["StatusNET"] as? [String:Any])?["Mac"] as? String == BulbProfile.original.mac)
            print("PASS: native HTTP client identifies the live bulb (read only)")
            if CommandLine.arguments.contains("--exercise") {
                let originalState = status["StatusSTS"] as! [String:Any]
                let originalAuto = try await client.command("Mem2")["Mem2"] as? String ?? "0"
                let originalOption = try await client.command("SetOption20")["SetOption20"] as? String ?? "OFF"
                let originalColor = originalState["Color"] as! String
                let restore = ["Speed2 !", "Color \(originalColor)", "Fade \(originalState["Fade"] as? String == "ON" ? 1 : 0)", "Scheme \(originalState["Scheme"] as? Int ?? 0)", "SetOption20 \(originalOption == "ON" ? 1 : 0)", "Mem2 \(originalAuto)"]
                let live = LightModel()
                do {
                    live.connect(); try await settled(live)
                    try require(live.online && live.selectedProfile.mac == BulbProfile.original.mac, "Could not connect to the original bulb")
                    // Exercise the real scheduler at a shortened interval, without changing the saved pace.
                    live.artInterval = 3
                    live.startComposition(LightComposition.all[0]); try await settled(live)
                    try require(live.activeComposition?.id == "ember", "Ember did not start: \(live.message)")
                    let deadline = Date().addingTimeInterval(80)
                    while live.artStep < 1 && live.activeComposition != nil && Date() < deadline {
                        try await Task.sleep(nanoseconds: 500_000_000)
                    }
                    try require(live.artStep >= 1 && live.activeComposition?.id == "ember", "Live composition did not advance: \(live.message)")
                    live.stopComposition(); try await settled(live)
                    let state = try await client.command("State")
                    try require(state["Dimmer"] as? Int == originalState["Dimmer"] as? Int, "Composition changed brightness")
                    let hold = state["Color"] as? String
                    try await Task.sleep(nanoseconds: 4_000_000_000)
                    let held = try await client.command("State")
                    try require(held["Color"] as? String == hold, "Stopped composition still sent a color")
                    print("PASS: real Ember scheduler advances, preserves brightness, stops and holds")
                    live.setColor("FF9B4300"); try await settled(live)
                    try require(live.online, "Edison command failed")
                    let edison = try await client.command("State")
                    try require(edison["Dimmer"] as? Int == originalState["Dimmer"] as? Int, "Edison changed brightness")
                    print("PASS: Edison mood accepted by bulb")
                } catch {
                    live.stopComposition()
                    for c in restore { _ = try? await client.command(c) }
                    throw error
                }
                for c in restore { _ = try await client.command(c) }
                print("RESTORED: previous light color and automatic-mode setting")
            }
        }
    }
    @MainActor static func settled(_ model:LightModel) async throws {
        let deadline = Date().addingTimeInterval(120)
        while model.busy && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        if model.busy { throw BulbError(message:"Model operation timed out") }
    }
}
