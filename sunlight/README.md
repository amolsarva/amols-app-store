# Sunlight

## Version 1.3 — bulb-native switch modes and chime

The bulb now owns the useful behavior: a normal power-up selects Edison warmth, a second quick power-cycle selects warm-neutral light, and a third selects a restrained daytime palette. Each selection gives three short bell-like blinks. The hourly chime is also native to the bulb, so Sunlight and the Mac may be closed.

`SetOption65 1` disables Tasmota's fast power-cycle recovery because seven rapid cycles can otherwise reset the device. `PowerOnState 1` makes a physical wall-switch power-up turn the lamp on reliably. The program uses persistent Tasmota rules and timers; it does not flash a new binary.

## Version 1.2 — hourly light chime

The **Clock** tab adds an optional hourly light chime for the selected bulb. It uses the familiar twelve-hour count: one blink at 1, twelve at noon and midnight. **Blink now** plays the current hour's count without changing the toggle. Tasmota performs each finite sequence and restores the bulb's prior on/off state; Sunlight also restores the prior fade and blink settings. The toggle is stored separately for each saved bulb.

The older Mac-side scheduler remains available for manual testing and for bulbs that have not installed the native program. The bulb-native program is preferred for this W31-N15.

## Version 1.1 — moods, compositions, and saved bulbs

Choose a saved light from the **Bulb** picker at the top of the window or the menu-bar menu. **Add bulb…** opens a form for its name, address, and optional web password. Verification reads its Tasmota status before saving its MAC identity. Commands check that identity, including each moving-composition step, so DHCP address reuse cannot silently retarget controls. Adding the same identity again updates its name/address. Passwords stay in memory only. Saved bulbs and the selected bulb survive app restarts.

The new light needs to be on your Wi-Fi and already expose compatible Tasmota RGB lighting controls. The app does not provision Wi-Fi or flash stock Sengled bulbs. Pairing does not change the new bulb's configuration. The daylight installer remains restricted to the original, verified W31-N15; other compatible lights can use moods and compositions.

Still moods: **Edison, Sunset, Candle, Reading room, Paper lantern, Rose quartz, Moonlight, Lagoon, Velvet, Morning, Daylight, Pure white**. Basic red/green/blue and the custom picker are retained. White controls are disabled on RGB-only devices.

Slow compositions:

| Composition | Palette |
| --- | --- |
| Ember | Gold, copper, ember |
| Blue Hour | Dusty blue, lavender, twilight |
| Aurora | Sea glass, jade, soft violet |
| Color Field | Oxblood, rust, apricot |
| Tidal | Ocean, turquoise, moonlit water |
| Desert dusk | Sandstone, terracotta, dusty rose |

Choose a **45-second, 90-second, or three-minute** dwell per color. Tasmota fades between stops (temporary `Speed2 40`, up to 20 seconds for a full-range fade). Brightness is preserved. Each composition loops its palette and pauses this app's daylight program. **Stop and hold color** freezes the current color. Selecting a static mood, switching bulbs, turning the bulb off through the app, or enabling daylight stops the composition. An offline/off bulb also stops the loop once detected. After a network failure, reconnect and restart a composition explicitly.

Compositions run in the **Mac app**: keep it open and the Mac awake. Sleep pauses updates, and quitting leaves the last color; compositions do not automatically resume after app relaunch. The original daily sunlight program continues to run in the bulb when enabled. Switching bulbs stops the current composition rather than transferring it or controlling all saved bulbs together.

Use `bash tests/run.sh` for dependency-free Swift checks of identity validation, saved-profile migration, palette looping and selection safeguards. `--live` adds read-only native transport verification. `--exercise` briefly tests Ember and Edison on the original bulb and restores its color/automation setting. The test harness needs only Apple's Command Line Tools, not XCTest or full Xcode.

A native SwiftUI Mac app for your Sengled W31-N15 running Tasmota. Open **Backstage → Scripts → Sunlight**, or double-click `dist/Sunlight.app`. The menu-bar sun also offers quick controls.

## Controls

- Power and brightness; sunset, candle, morning, daylight, RGB and dedicated-white presets.
- Native color picker, simulated color temperature, dedicated white-channel level.
- Daily cycle on/off, timezone selection, clock sync, status, private backup, console and restart.
- Choosing a color pauses automation. Brightness changes do not. Automatic color updates never turn an off bulb on.

## On-device daylight program

Tasmota 15.6.0 already contains the required clock and rule engine. This app installs a persistent **rules program**, not a replacement firmware binary. No OTA firmware upload is necessary. It uses Rule1–3, Mem1–4 and RuleTimer1/3. The installer refuses unrelated existing rules, verifies device MAC/hardware, backs up settings, and reads each rule back before enabling it.

Power-on uses Edison amber (`FF9B4300`) at the current brightness. At hourly updates, the bulb uses its local time: amber night, dawn at 06:00, warm morning, neutral noon, golden afternoon, sunset at 18:00 and amber evening. These are illustrative RGBW colors, not calibrated color temperatures or seasonal solar calculations. The initial timezone is America/New_York, matching the Mac context; change it in Daylight if the bulb is elsewhere.

Without synchronized time, the simulated clock starts at 12:00 on installation. It advances 60 minutes per hour and 180 minutes on restart, wrapping at midnight; its last hour is stored persistently. On acquiring network time, the bulb resumes using real local time. Warm startup takes precedence immediately after power-on; the simulated clock affects subsequent updates. The first reboot after installation advances the stored noon clock to 15:00.

The Mac does not need to remain awake. NTP is re-enabled after a manual clock sync. `SetOption20 1` prevents color changes from switching an off light on. `SetOption65 1` prevents rapid wall-switch cycling from invoking Tasmota's recovery reset. `PowerOnState 1` ensures the lamp comes on after a physical power restoration. Brightness is preserved with `Color2`. `Fade 1` / `Speed 10` provide gentle transitions.

## Recovery

Settings backups contain Wi-Fi credentials. They are stored with private permissions in `backupDirectory` from `local-bulb.json` (default `~/Library/Application Support/Sunlight/Backups/`), never committed to this repository. Use Tasmota → Configuration → Restore Configuration for a full rollback. Restore only a backup from this exact bulb. A settings backup is **not** a full flash image.

To pause the cycle, disable it in the app (`Mem2 0`). To disable all Sunlight rules, use `Rule1 0`, `Rule2 0`, `Rule3 0` in the Tasmota console. This also disables warm startup. No factory reset, credentials change, GPIO reassignment, or firmware upload is part of installation.

If an installation loses connectivity, it reports incomplete rather than assuming success. Reconnect and inspect before retrying. Wi-Fi was intermittent during setup, so a firmware upload would carry an unnecessary interruption risk. No flashing procedure can guarantee zero failures.

## Build and maintenance

Run `bash build.sh` using Apple's Command Line Tools. Builds and the signed app live outside iCloud in `~/Library/Caches/sunlight-build`; `dist/Sunlight.app` links there. This avoids iCloud metadata interfering with code signing. `run.sh` rebuilds if the cache is removed and works from any working directory. The app talks directly to the bulb over local HTTP, supplies the required Referer header, uses optional HTTP authentication, and verifies its identity before changing it.

`python3 tools/device.py selftest` validates the program structure and clock wrap cases. `inspect`, `backup`, `export`, `install`, and `command 'State'` are maintenance commands. `install` is for this specific bulb and uses New York time; the app provides other timezones.

Sources: https://tasmota.github.io/docs/Rules/ ; https://tasmota.github.io/docs/Commands/ ; https://templates.blakadder.com/sengled_W31-N15.html

## Your bulb (kept off GitHub)

Nothing about a specific device is compiled in. Copy `local-bulb.example.json` to `local-bulb.json`
(git-ignored, so it stays on your Macs) and fill in your bulb; `run.sh` loads it into the app's
settings on first launch. `daylightVerifiedMAC` is the one bulb you've tested the daylight rules on.
Without the file, pair a bulb from the app's bulb picker.
