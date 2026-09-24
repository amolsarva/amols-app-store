import Foundation

enum LightChime {
    static func calendar(_ timeZone: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: timeZone) ?? .current
        return c
    }
    static func count(at date: Date, timeZone: String) -> Int {
        let hour = calendar(timeZone).component(.hour, from: date) % 12
        return hour == 0 ? 12 : hour
    }
    static func hour(at date: Date, timeZone: String) -> Date {
        calendar(timeZone).dateInterval(of: .hour, for: date)!.start
    }
    static func key(_ id: UUID) -> String { "hourlyChime.v1.\(id.uuidString)" }
}

// Never catch up missed hours or replay an hour after the system clock moves back.
// A small delay lets the on-device daylight rule finish its hourly color change.
struct ChimeSchedule {
    private var latestHour: Date
    private var previousTick: Date
    init(now: Date, timeZone: String) {
        latestHour = LightChime.hour(at: now, timeZone: timeZone)
        previousTick = now
    }
    mutating func due(now: Date, timeZone: String, available: Bool) -> Int? {
        let hour = LightChime.hour(at: now, timeZone: timeZone)
        let age = now.timeIntervalSince(hour)
        let gap = now.timeIntervalSince(previousTick)
        previousTick = now
        guard hour > latestHour else { return nil }
        if gap > 15 || age > 12 { latestHour = hour; return nil }
        guard age >= 2, available else { return nil }
        latestHour = hour // Consume before starting any network operation: never retry a chime.
        return LightChime.count(at: now, timeZone: timeZone)
    }
}

extension BulbClient {
    // Native finite blinking restores power even if the Mac disappears mid-chime.
    // No color/power commands or rule edits are necessary; those would trigger warm startup.
    func chime(count: Int) async throws -> [String: Any] {
        guard (1...12).contains(count) else { throw BulbError(message: "A chime must have 1–12 blinks.") }
        _ = try await identify()
        let state = try await command("State")
        guard let fade = state["Fade"] as? String,
              let oldColor = state["Color"] as? String,
              let oldCount = try await command("BlinkCount")["BlinkCount"] as? Int,
              let oldTime = try await command("BlinkTime")["BlinkTime"] as? Int else {
            throw BulbError(message: "This bulb did not provide the settings needed for a reversible chime.")
        }
        let restore = ["Color2 \(oldColor)", "Fade \(fade == "ON" ? 1 : 0)", "BlinkCount \(oldCount)", "BlinkTime \(oldTime)"]
        var failure: Error?
        do {
            _ = try await command("Fade 0")
            _ = try await command("BlinkTime 7")
            _ = try await command("BlinkCount \(count)")
            let started = try await command("Power1 3")
            guard started["POWER1"] as? String == "BLINK ON" || started["POWER"] as? String == "BLINK ON" else {
                throw BulbError(message: "The bulb did not confirm that blinking started.")
            }
            try await Task.sleep(nanoseconds: UInt64((Double(count) * 1.4 + 1.0) * 1_000_000_000))
        } catch { failure = error }
        // Recheck identity before cleanup; a recycled DHCP address must never retarget writes.
        _ = try await identify()
        if failure != nil { _ = try? await command("Power1 4") }
        var cleanupFailed = false
        for c in restore {
            do { _ = try await command(c) } catch { cleanupFailed = true }
        }
        if cleanupFailed {
            throw BulbError(message: "The finite blink sequence will stop itself, but restoring fade/blink settings could not be confirmed. Reconnect and check the bulb.")
        }
        if let failure { throw failure }
        return try await command("State")
    }
}
