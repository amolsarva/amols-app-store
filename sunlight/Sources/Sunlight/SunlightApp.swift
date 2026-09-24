import SwiftUI
import AppKit


struct ControlView: View {
    @EnvironmentObject var light: LightModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 18) {
                    Image(systemName: light.power ? "lightbulb.max.fill" : "lightbulb.slash")
                        .font(.system(size: 58)).foregroundStyle(.orange).frame(width: 90)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("A little sunshine, on demand.").font(.title2.bold())
                        Text(light.power ? "Light is on" : "Light is off").foregroundStyle(.secondary)
                        Text(light.activeComposition?.name ?? (light.automatic ? "Following the day" : "Manual color")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(light.power ? "Turn off" : "Turn on") { light.send(light.power ? "Power Off" : "Power On") }
                        .buttonStyle(.borderedProminent).tint(.orange).controlSize(.large)
                }
                GroupBox("Brightness") {
                    HStack {
                        Image(systemName: "sun.min")
                        Slider(value: $light.brightness, in: 1...100, step: 1, onEditingChanged: { editing in
                            if !editing { light.send("Dimmer \(Int(light.brightness))") }
                        }).accessibilityLabel("Brightness")
                        Text("\(Int(light.brightness))%").monospacedDigit().frame(width: 42)
                    }.padding(10)
                }
                Text("Choose a mood").font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170))], spacing: 10) {
                    ForEach(LightMood.all.filter { light.supportsWhite || $0.id != "white" }) { mood in
                        Button { light.setColor(mood.hex) } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Circle().fill(mood.id == "white" ? Color.white : DaylightView.rgb(mood.hex))
                                    .overlay(Circle().strokeBorder(.gray.opacity(0.25))).frame(width: 18, height: 18)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(mood.name).font(.headline)
                                    Text(mood.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Spacer(minLength: 0)
                            }.frame(maxWidth: .infinity, minHeight: 54, alignment: .leading).padding(8)
                        }.buttonStyle(.bordered).help(mood.detail)
                    }
                }
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Slow color compositions").font(.headline)
                        Text("Small palettes, unhurried changes.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("Pace", selection: $light.artInterval) {
                        Text("Drift · 45s").tag(45.0)
                        Text("Slow · 90s").tag(90.0)
                        Text("Very slow · 3m").tag(180.0)
                    }.frame(width: 205)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220))], spacing: 10) {
                    ForEach(LightComposition.all) { composition in
                        Button { light.startComposition(composition) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(LinearGradient(colors: composition.colors.map(DaylightView.rgb), startPoint: .leading, endPoint: .trailing))
                                    .frame(height: 22)
                                HStack {
                                    Text(composition.name).font(.headline)
                                    Spacer()
                                    Image(systemName: light.activeComposition?.id == composition.id ? "waveform" : "play.fill")
                                }
                                Text(composition.detail).font(.caption).foregroundStyle(.secondary)
                            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.bordered)
                    }
                }
                if let art = light.activeComposition {
                    HStack {
                        Label("\(art.name) · color \(light.artStep + 1)/\(art.colors.count)", systemImage: "waveform")
                        Spacer()
                        Button("Stop and hold color") { light.stopComposition() }
                    }.padding(10).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                Text("Compositions preserve brightness and pause daylight. Keep Sunlight open and this Mac awake; closing it leaves the last color. Switching bulbs stops the active composition.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                HStack {
                    ColorPicker("Custom color", selection: $light.color, supportsOpacity: false)
                    Button("Apply color") { light.pickColor() }
                }
                HStack {
                    preset("Red", "circle.fill", "FF000000", .red)
                    preset("Green", "circle.fill", "00FF0000", .green)
                    preset("Blue", "circle.fill", "0000FF00", .blue)
                }
                GroupBox("White light") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Warm ← Color temperature → Cool").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Slider(value: $light.temperature, in: 2000...6500, step: 100)
                                .accessibilityLabel("Color temperature")
                            Text("\(Int(light.temperature)) K").monospacedDigit().frame(width: 64)
                            Button("Apply") { light.send("CT \(Int(1_000_000 / light.temperature))", manual: true) }
                        }
                        HStack {
                            Text("White channel")
                            Slider(value: $light.white, in: 0...100, step: 1)
                            Button("Apply") { light.send("Channel4 \(Int(light.white))", manual: true) }
                        }
                        Text("Color temperature is simulated on this RGBW bulb. Pure white uses its dedicated white LEDs.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }.disabled(!light.supportsWhite)
                Text("Choosing a color pauses the daily cycle. Brightness stays under your control. Off stays off.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }.disabled(light.busy || !light.online)
    }
    func preset(_ name: String, _ symbol: String, _ hex: String, _ tint: Color) -> some View {
        Button { light.setColor(hex) } label: {
            Label(name, systemImage: symbol).frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }.tint(tint).buttonStyle(.bordered)
    }
}

struct ChimeView: View {
    @EnvironmentObject var light: LightModel
    var body: some View {
        Form {
            Section {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    VStack(alignment: .leading, spacing: 10) {
                        Label("A church bell, made of light.", systemImage: "bell.badge.waveform.fill").font(.title2.bold())
                        Text(Self.clockText(timeline.date, timeZone: light.selectedProfile.timeZone))
                            .font(.system(size: 40, weight: .light, design: .rounded)).monospacedDigit()
                        Text("\(light.selectedProfile.name) · \(light.selectedProfile.timeZone)")
                            .foregroundStyle(.secondary)
                    }.padding(.vertical, 12)
                }
            }
            Section("Hourly light chime") {
                Toggle("Chime on the hour", isOn: Binding(get: { light.chimeEnabled }, set: { light.setChimeEnabled($0) }))
                    .toggleStyle(.switch).disabled(light.chiming)
                Text("One blink at 1, two at 2, up to twelve at noon and midnight. Each blink has a 0.7-second light phase and a 0.7-second dark phase.")
                HStack {
                    Button { light.blinkNow() } label: { Label("Blink now", systemImage: "bell.fill") }
                        .buttonStyle(.borderedProminent).tint(.orange).disabled(light.busy)
                    if light.chiming { ProgressView().controlSize(.small) }
                    Text("Plays the current hour’s count, even when the toggle is off.").font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 6)
                Text(light.chimeMessage).textSelection(.enabled)
            }
            Section("How it works") {
                Text("Keep Sunlight open and this Mac awake. The toggle is remembered per bulb; only the currently selected bulb chimes. Change its timezone in Daylight.")
                Text("An off bulb briefly lights for the chime and returns to off. An on bulb briefly goes dark between strikes. Color and brightness are preserved; a running composition resumes afterward.")
                Text("No catch-up chimes after sleep or relaunch. A busy or unreachable bulb may miss an hour. The daylight program still runs independently inside the bulb.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
    static func clockText(_ date: Date, timeZone: String) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: timeZone) ?? .current
        formatter.dateFormat = "h:mm:ss a"
        return formatter.string(from: date)
    }
}

struct DaylightView: View {
    @EnvironmentObject var light: LightModel
    var body: some View {
        Form {
            Section("Daily rhythm") {
                Toggle("Follow the day automatically", isOn: Binding(get: { light.automatic }, set: { light.setAutomatic($0) }))
                    .disabled(!light.programInstalled || light.busy)
                Text("Runs inside the bulb, even with this Mac asleep. Each power-on starts in sunset amber. The clock selects a warm dawn, neutral noon, golden afternoon, and amber evening at hourly updates.")
                Text("This version follows local clock time, with dawn at 06:00 and sunset at 18:00. It does not calculate seasonal sunrise from your location.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 0) {
                    ForEach(Array(DaylightProgram.palette.enumerated()), id: \.offset) { _, p in
                        VStack(spacing: 6) {
                            Rectangle().fill(Self.rgb(p.1)).frame(height: 35)
                            Text(String(format: "%02d", p.0 / 60)).font(.caption2.monospacedDigit())
                        }
                    }
                }.padding(.vertical, 8)
                Button("Apply this hour’s color now") { light.send("Event tick") }.disabled(!light.programInstalled)
            }
            Section("Clock") {
                Picker("Bulb timezone", selection: $light.timeZone) {
                    ForEach(["America/New_York", "America/Los_Angeles", "Europe/Paris", "Europe/London", "UTC"], id: \.self) { Text($0).tag($0) }
                }
                Button("Save timezone and sync from Mac") { light.configureClock() }
                LabeledContent("Bulb time", value: light.deviceTime)
                Text("Without network time, the simulated day starts at noon on installation, advances every hour, and advances three hours on each reboot. It returns to real time after synchronization.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("On-device program") {
                LabeledContent("Status", value: light.programInstalled ? "Installed" : "Not yet verified")
                Button("Install / repair daylight program…") { light.installConfirmation = true }.disabled(!light.canInstallDaylight)
                if !light.canInstallDaylight {
                    Text("Daylight rules install only on a bulb you have tested and listed as daylightVerifiedMAC in local-bulb.json. Other bulbs can use moods and compositions without replacing their rules.").font(.caption).foregroundStyle(.secondary)
                }
                Text("Saves a private recovery backup, verifies the bulb’s identity, then installs Tasmota rules. No firmware binary replacement is required.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).disabled(light.busy)
        .confirmationDialog("Install the daylight program on this bulb?", isPresented: $light.installConfirmation) {
            Button("Back up and install") { light.installProgram() }
        } message: { Text("Uses Rule1–3 and Mem1–2. Existing unrelated rules will stop installation. A dropped connection may leave installation incomplete; the app will report it.") }
    }
    static func rgb(_ hex: String) -> Color {
        let n = UInt32(hex.prefix(6), radix: 16) ?? 0
        return Color(red: Double((n >> 16) & 255)/255, green: Double((n >> 8) & 255)/255, blue: Double(n & 255)/255)
    }
}

struct DeviceView: View {
    @EnvironmentObject var light: LightModel
    var body: some View {
        Form {
            Section("Selected bulb · \(light.selectedProfile.name)") {
                LabeledContent("Device identity", value: light.selectedProfile.mac)
                TextField("IP / hostname (update if it changes)", text: $light.host)
                SecureField("Web password (if set)", text: $light.password)
                Text("Password is kept only while this app is open.").font(.caption).foregroundStyle(.secondary)
                Button("Connect / refresh") { light.connect() }.keyboardShortcut("r", modifiers: .command)
                LabeledContent("Firmware", value: light.version)
                LabeledContent("Wi-Fi signal", value: light.signal)
                LabeledContent("Uptime", value: light.uptime)
                LabeledContent("Current RGBW output", value: light.colorHex)
            }
            Section("Add a bulb already on your Wi-Fi") {
                TextField("Name, e.g. Desk or Bedroom", text: $light.draftName)
                TextField("IP address or hostname", text: $light.draftHost)
                SecureField("Web password, if set", text: $light.draftPassword)
                Button("Verify and save bulb") { light.addBulb() }
                Text("Reads the bulb first, then saves its unique identity. Adding the same bulb again updates its name/address without creating a duplicate. Passwords stay in memory only.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("For a new bulb: finish its model-specific Tasmota setup, join it to your Wi-Fi, then enter its address here. This app does not flash unconfigured bulbs or change their Wi-Fi settings. A stock Sengled bulb is not automatically compatible.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Recovery and advanced controls") {
                Button("Save settings backup") { light.backup() }
                if !light.backupPath.isEmpty {
                    Button("Reveal recovery backup") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: light.backupPath)]) }
                }
                Button("Open Tasmota controls") { openWeb("") }
                Button("Open Tasmota console") { openWeb("cs") }
                Button("Restart bulb…") { light.restartConfirmation = true }
                Text("Recovery files contain Wi-Fi credentials and are stored in your private keys vault, outside the app repository.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Activity") {
                Text(light.log.isEmpty ? "No activity yet." : light.log).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
        }.formStyle(.grouped).disabled(light.busy)
        .confirmationDialog("Restart this bulb?", isPresented: $light.restartConfirmation) {
            Button("Restart") { light.send("Restart 1") }
        } message: { Text("The connection will briefly drop. The fallback clock advances three hours on reboot.") }
    }
    func openWeb(_ path: String) {
        if (try? BulbClient(host: light.host)) != nil, let url = URL(string: "http://\(light.host)/\(path)") { NSWorkspace.shared.open(url) }
    }
}

struct MainView: View {
    @EnvironmentObject var light: LightModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "lightbulb.2.fill").foregroundStyle(.orange)
                Picker("Bulb", selection: Binding(get: { light.selectedID }, set: { light.selectBulb($0) })) {
                    ForEach(light.profiles) { profile in Text(profile.name).tag(profile.id) }
                }.frame(maxWidth: 320).disabled(light.busy)
                Text(light.selectedProfile.host).font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Button("Add bulb…") { light.selectedTab = "bulbs" }.disabled(light.busy)
            }.padding(14)
            Divider()
            TabView(selection: $light.selectedTab) {
                ControlView().tabItem { Label("Light", systemImage: "lightbulb") }.tag("light")
                DaylightView().tabItem { Label("Daylight", systemImage: "sun.horizon") }.tag("daylight")
                DeviceView().tabItem { Label("Bulbs", systemImage: "slider.horizontal.3") }.tag("bulbs")
                ChimeView().tabItem { Label("Clock", systemImage: "clock") }.tag("clock")
            }
            Divider()
            HStack(alignment: .center) {
                Circle().fill(light.online ? .green : .orange).frame(width: 8, height: 8)
                if light.busy { ProgressView().controlSize(.small) }
                Text(light.message).font(.caption).lineLimit(3).textSelection(.enabled)
                Spacer()
                Button { light.connect() } label: { Image(systemName: "arrow.clockwise") }.disabled(light.busy).help("Reconnect and refresh")
            }.padding(12)
        }.frame(minWidth: 660, minHeight: 700)
        .task { light.startChimeClock(); light.connect() }
    }
}

@main
struct SunlightApp: App {
    @StateObject private var light = LightModel()
    var body: some Scene {
        Window("Sunlight", id: "sunlight") { MainView().environmentObject(light) }
            .defaultSize(width: 740, height: 820)
        MenuBarExtra("Sunlight", systemImage: "sun.max.fill") {
            Text(light.selectedProfile.name)
            Menu("Choose bulb") {
                ForEach(light.profiles) { p in Button(p.name) { light.selectBulb(p.id) }.disabled(light.busy) }
            }
            Button(light.power ? "Turn off" : "Turn on") { light.send(light.power ? "Power Off" : "Power On") }
            Button("Edison") { light.setColor("FF9B4300") }
            Button("Sunset") { light.setColor(DaylightProgram.sunset) }
            Button("Daylight") { light.setAutomatic(true) }
            if light.activeComposition != nil { Button("Stop composition") { light.stopComposition() } }
            Divider()
            Toggle("Hourly chime", isOn: Binding(get: { light.chimeEnabled }, set: { light.setChimeEnabled($0) })).disabled(light.chiming)
            Button("Blink now") { light.blinkNow() }.disabled(light.busy)
            Divider()
            ShowWindowButton()
            Button("Quit Sunlight") { NSApplication.shared.terminate(nil) }.disabled(light.chiming)
        }
    }
}

struct ShowWindowButton: View {
    @Environment(\.openWindow) var openWindow
    var body: some View {
        Button("Open Sunlight") { openWindow(id: "sunlight"); NSApplication.shared.activate(ignoringOtherApps: true) }
    }
}
