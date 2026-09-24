import Foundation

enum DaylightProgram {
    static let sunset = "FF9B4300"
    static let legacyRules: [String] = [
        "ON Power1#Boot DO Color2 FF780000 ENDON ON Power1#State=1 DO Color2 FF780000 ENDON ON System#Init DO Backlog Var1 0; Var2 %mem1%; Event advance=180; RuleTimer1 3600 ENDON ON Time#Initialized DO Var1 1 ENDON ON Time#Set DO Var1 1 ENDON ON Time#Minute|60 DO Event tick ENDON ON Rules#Timer=1 DO Backlog Event advance=60; RuleTimer1 3600; RuleTimer2 5 ENDON ON Rules#Timer=2 DO Event tick ENDON",
        "ON Event#advance DO Backlog Add2 %value%; Event wrap ENDON ON Event#wrap DO Backlog Event over=%var2%; Event save ENDON ON Event#over>=1440 DO Sub2 1440 ENDON ON Event#save DO Mem1 %var2% ENDON ON Event#tick DO Event auto=%mem2% ENDON ON Event#auto=1 DO Event clock=%var1% ENDON ON Event#clock=1 DO Event sun=%time% ENDON ON Event#clock=0 DO Event sun=%mem1% ENDON ON Event#paint DO Color2 %var3% ENDON",
        "ON Event#sun DO Var3 FF380000 ENDON ON Event#sun>=360 DO Var3 FF780000 ENDON ON Event#sun>=480 DO Var3 FFBB7000 ENDON ON Event#sun>=600 DO Var3 FFE4BE00 ENDON ON Event#sun>=720 DO Var3 FFF4E500 ENDON ON Event#sun>=900 DO Var3 FFE4BE00 ENDON ON Event#sun>=1020 DO Var3 FFBB7000 ENDON ON Event#sun>=1080 DO Var3 FF780000 ENDON ON Event#sun>=1200 DO Var3 FF500000 ENDON ON Event#sun>=1320 DO Var3 FF380000 ENDON ON Event#sun DO Event paint ENDON"
    ]
    // Wall-clock palette. RGBW values are a visual approximation, not calibrated kelvin.
    static let palette: [(Int, String, String)] = [
        (0,"FF380000","Night amber"), (360,"FF780000","Dawn"),
        (480,"FFBB7000","Morning"), (600,"FFE4BE00","Late morning"),
        (720,"FFF4E500","Noon"), (900,"FFE4BE00","Afternoon"),
        (1020,"FFBB7000","Golden hour"), (1080,"FF780000","Sunset"),
        (1200,"FF500000","Evening"), (1320,"FF380000","Night amber")]

    static func color(minute: Int) -> String {
        palette.last(where: { minute >= $0.0 })!.1
    }

    // Mem1 = fallback minutes; Mem2 = daylight mode; Mem3 = quick-cycle mode; Mem4 = last boot minute.
    // Mode 1 is Edison warm, mode 2 is warm-neutral, and mode 3 is the daylight cycle.
    // Compact event names preserve Tasmota's 512-byte rule-set limit.
    static let rules: [String] = [
        "ON Power1#Boot DO Color2 FF9B4300 ENDON " +
        "ON System#Init DO Backlog Var1 0;Var2 %mem1%;RuleTimer1 3600 ENDON " +
        "ON Time#Initialized DO Backlog Var1 1;RuleTimer1 0;Var4 %time%;Sub4 %mem4%;IF (%var4%<0) Add4 1440 ENDIF;Event q=%var4%;Mem4 %time% ENDON " +
        "ON Time#Minute|60 DO Event h ENDON " +
        "ON Rules#Timer=1 DO Backlog Event a=60;RuleTimer1 3600;Event h ENDON " +
        "ON Event#q<3 DO Event n=%mem3% ENDON " +
        "ON Event#q>=3 DO Event n=0 ENDON " +
        "ON Event#c=1 DO Event d=%time% ENDON " +
        "ON Event#c=0 DO Event d=%mem1% ENDON",

        "ON Event#a DO Backlog Add2 %value%;Event w ENDON " +
        "ON Event#w DO Backlog Event o=%var2%;Event s ENDON " +
        "ON Event#o>=1440 DO Sub2 1440 ENDON " +
        "ON Event#s DO Mem1 %var2% ENDON " +
        "ON Event#h DO Backlog Event t;Event b ENDON " +
        "ON Event#t DO Event c=%mem2% ENDON " +
        "ON Event#n=0 DO Backlog Mem3 1;Mem2 0;Color2 FF9B4300;Event b ENDON " +
        "ON Event#n=1 DO Backlog Mem3 2;Mem2 0;Color2 FFE4BE00;Event b ENDON " +
        "ON Event#n=2 DO Backlog Mem3 3;Mem2 1;Event t;Event b ENDON " +
        "ON Event#n>=3 DO Event n=0 ENDON",

        "ON Event#d DO Color2 FF380000 ENDON " +
        "ON Event#d>=360 DO Color2 FF780000 ENDON " +
        "ON Event#d>=540 DO Color2 FFBB7000 ENDON " +
        "ON Event#d>=720 DO Color2 FFF4E500 ENDON " +
        "ON Event#d>=960 DO Color2 FFBB7000 ENDON " +
        "ON Event#d>=1080 DO Color2 FF780000 ENDON " +
        "ON Event#d>=1200 DO Color2 FF500000 ENDON " +
        "ON Event#b DO Backlog Fade 0;BlinkTime 7;BlinkCount 3;RuleTimer3 8;Power1 3 ENDON " +
        "ON Rules#Timer=3 DO Backlog Fade 1;BlinkTime 10;BlinkCount 10 ENDON"
    ]
}

struct BulbError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

actor BulbClient {
    let host: String
    let password: String
    let expectedMAC: String?
    let session: URLSession
    init(host: String, password: String = "", expectedMAC: String? = nil) throws {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil else {
            throw BulbError(message: "Enter a hostname or IPv4 address without http:// or a path.")
        }
        self.host = trimmed
        self.password = password
        self.expectedMAC = expectedMAC
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 1
        session = URLSession(configuration: config)
    }
    func request(path: String, command: String? = nil) async throws -> Data {
        var url = URLComponents(string: "http://\(host)/\(path)")!
        if let command { url.queryItems = [URLQueryItem(name: "cmnd", value: command)] }
        var req = URLRequest(url: url.url!)
        req.setValue("http://\(host)/", forHTTPHeaderField: "Referer")
        if !password.isEmpty {
            req.setValue("Basic " + Data("admin:\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        }
        let nonrepeatable = !Self.canRetry(command)
        for attempt in 0...(nonrepeatable ? 0 : 2) {
            do {
                let (data, response) = try await session.data(for: req)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw BulbError(message: "Bulb returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0). Check its address and password.")
                }
                return data
            } catch let error as URLError where !nonrepeatable && attempt < 2 {
                guard [.timedOut, .cannotConnectToHost, .networkConnectionLost].contains(error.code) else { throw error }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        throw BulbError(message: "The bulb did not respond. Check its power and Wi-Fi.")
    }
    nonisolated static func canRetry(_ command: String?) -> Bool {
        guard let command = command?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) else { return true }
        if ["event ", "restart "].contains(where: { command.hasPrefix($0) }) { return false }
        // Retrying an ambiguous blink/toggle response could create a second chime.
        return command.range(of: "^power[0-9]*\\s+(3|blink|2|toggle)$", options: .regularExpression) == nil
    }
    func command(_ command: String) async throws -> [String: Any] {
        let data = try await request(path: "cm", command: command)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BulbError(message: "The device did not return a Tasmota response.")
        }
        if json["Warning"] != nil || json["Command"] as? String == "Unknown" {
            throw BulbError(message: "Command rejected: \(String(decoding: data, as: UTF8.self))")
        }
        return json
    }
    func identify() async throws -> [String: Any] {
        let status = try await command("Status 0")
        _ = try BulbProfile.compatibleStatus(status, expectedMAC: expectedMAC)
        return status
    }
    func backup() async throws -> URL {
        _ = try await identify()
        let data = try await request(path: "dl")
        guard data.count >= 4096, data.count <= 32768,
              !String(decoding: data.prefix(80), as: UTF8.self).lowercased().contains("<html") else {
            throw BulbError(message: "Invalid settings backup; configuration was not changed.")
        }
        // Backups hold Wi-Fi credentials: a private folder, never the app repository.
        let directory = UserDefaults.standard.string(forKey: "backupDirectory").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Sunlight/Backups")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let identity = ((expectedMAC?.isEmpty == false ? expectedMAC : nil) ?? host).replacingOccurrences(of: ":", with: "")
        let url = directory.appendingPathComponent("bulb-\(identity)-\(stamp)-\(UUID().uuidString.prefix(6)).dmp")
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }
}
