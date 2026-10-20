# BatteryKeeper v0.1 design

BatteryKeeper is a macOS menu bar app for Apple silicon MacBooks. It replaces the parts of AlDente Pro its
owner uses: a scheduled calibration cycle, battery statistics and a configurable menu bar icon, on top of the
charge limit that macOS itself enforces. See [research.md](research.md) for why the limit is left to macOS.

## Scope

1. **Daily charge limit, delegated to macOS.** The system Charge Limit (80, 85, 90, 95 or 100 %, about 5 %
   resume hysteresis, enforced by `powerd` and the firmware) is the source of truth. The app shows it, sets it
   and offers "Charge to Full Now". It runs no enforcement loop of its own outside a calibration cycle, so a
   limit set in System Settings is respected and a crashed or quit app changes nothing.
2. **Scheduled calibration cycle.** Every N days (default 28), and on demand: charge to 100 % → discharge
   while plugged in to a floor (default 15 %) → charge to 100 % → hold at 100 % for a while (default 1 h) →
   discharge to the daily limit → restore the daily limit.
3. **Battery statistics.** Health trend (full charge capacity vs design capacity, cycle count) over months;
   charge level and temperature over the last 24 h / 7 days; live power flow (adapter in, system load, battery
   in/out); an event log (plug, unplug, full, limit changes, cycle phases, helper state).
4. **Configurable menu bar icon.** Styles: battery glyph, ring, text only. Content, any combination of:
   percentage, power (W), temperature, time remaining. State shown by a badge/colour: charging, held at limit,
   on battery, discharging for a cycle.
5. Menu bar only (no Dock icon), launch at login, Developer ID signed and notarized.

Non-goals for v0.1: temperature protection, discharging above the limit in daily use, limits below 80 %,
MagSafe LED control, Intel Macs, macOS before 27, keeping a discharge going while the Mac sleeps.

The interface is in Simplified Chinese (English source strings, a generated String Catalog).

## Mechanisms

| Need | Mechanism | Privilege |
| --- | --- | --- |
| Read/set daily limit, charge to full now | private `PowerUI.framework`, `PowerUISmartChargeClient` (`getMCLLimitWithError:`, `setMCLLimit:error:`, `disableMCL:`, `temporarilyDisableMCL:`, `availableChargeLimitsWithError:`), loaded at runtime with `dlopen`. `setMCLLimit:` also switches the limit on; `enableMCL:` resets it to 80 and is only used when the limit stays off | none |
| Discharge while plugged in | SMC key `CHIE`: `0x08` cuts the adapter, `0x00` restores it | root: privileged helper |
| Battery state, health, power flow | IORegistry `AppleSmartBattery` (`CurrentCapacity`, `BatteryData`, `PowerTelemetryData`, `AdapterDetails`, `CycleCount`, `Voltage`, `Amperage`) | none |
| Battery temperature | SMC `TB0T` (float, °C), read-only | none |

The private API and the SMC key are the fragile parts: both are probed at launch and the app degrades to a
read-only statistics app with a visible message if either is missing.

## Components

Follows Piccolo's layout: everything testable in the root `Package.swift`, thin Xcode targets.

- `BatteryKeeperCore` (pure, fully unit tested): battery snapshot model, the calibration cycle state machine,
  the schedule, the adapter lease rules, statistics aggregation and downsampling, the menu bar icon model
  (which text and badge to show for a snapshot and settings), the settings schema.
- `BatteryKeeperBridge` (C/Objective-C): the AppleSMC parameter struct and the PowerUI client declarations.
- `BatteryKeeperSystem`: IORegistry battery reader, SMC reader, `ChargeLimitController` over PowerUI,
  helper XPC client, login item (`SMAppService.mainApp`), helper registration (`SMAppService.daemon`), sleep and
  power source notifications, SQLite store.
- `BatteryKeeper.app` (Xcode target, `App/`): `NSStatusItem` with a custom-drawn image, a SwiftUI popover,
  the Statistics window (Swift Charts) and the Settings window.
- `BatteryKeeperHelper` (Xcode command line target, `Helper/`): root launch daemon registered with
  `SMAppService.daemon`, shipped in `Contents/MacOS`, its plist in `Contents/Library/LaunchDaemons`.

Bundle IDs: app `io.damao.batterykeeper`; helper label and Mach service `io.damao.batterykeeper.helper`.
Swift 6, SwiftUI + AppKit, not sandboxed (IOKit user clients, private framework), hardened runtime on.

## Privileged helper and fail-safe

The helper does one thing: switch the adapter with `CHIE`. Its rules:

- The adapter can only be cut under a **lease**. The app asks for "adapter off for 90 s" and renews every
  30 s. When the lease runs out (app quit, crashed, hung), the helper restores the adapter.
- It restores the adapter on start, on `SIGTERM`, when the client connection is invalidated, when the system
  is about to sleep, and when the charge reaches a hard floor of 10 % whatever the app asked.
- It is a `KeepAlive` launch daemon, so a crash ends in a restart, and a restart restores the adapter.
- It accepts XPC connections only from `io.damao.batterykeeper` signed by team `T7976FL2LP`; the app only
  talks to a helper with the same requirement.

The charge limit needs no fail-safe of its own: it lives in `powerd`. If the app dies mid-cycle with the limit
lifted, the Mac charges to 100 % (plain macOS behaviour) until the app restarts and resumes or ends the cycle.

## Calibration cycle

Phases: `chargeToFull` → `dischargeToFloor` → `rechargeToFull` → `holdFull` → `dischargeToLimit` → done.
Transitions are a pure function of (phase, snapshot, time, settings) in `BatteryKeeperCore`.

- Start: the cycle is due (N days since the last completed one) and the Mac is awake and on power; or the user
  starts it from the menu. The limit in effect is saved and the system limit is disabled for the cycle.
- Discharge phases cut the adapter through the helper (leased) and hold a "prevent idle sleep" assertion. If
  the Mac sleeps anyway (lid closed), the helper restores the adapter and the cycle resumes after wake.
- Charge phases need power; unplugged, they wait. Discharge phases on battery just run.
- Finish or cancel: adapter restored, saved limit re-applied, event logged. The state is persisted, so a
  relaunch resumes a running cycle; a cycle older than 48 h is cancelled instead.
- A discharge from 100 % to 15 % takes several hours at idle; the menu shows the phase and progress.

## Statistics storage

SQLite in `~/Library/Application Support/BatteryKeeper/stats.sqlite`, schema versioned forward-only:

- `samples`: one row a minute while awake and on every power source change (charge %, temperature, voltage,
  amperage, battery power, system load, adapter watts, plugged in, charging, limit). Kept 30 days.
- `daily_health`: one row a day (full charge, nominal and design capacity, cycle count). Kept forever.
- `events`: timestamped events with a kind and a short detail. Kept forever.

## Build, sign, release

Mirrors Piccolo: `scripts/build.sh`, `scripts/install.sh`, `scripts/release.sh`, signing from
`${XDG_CONFIG_HOME:-$HOME/.config}/batterykeeper/signing.env` (`BATTERYKEEPER_CODESIGN_IDENTITY`,
`BATTERYKEEPER_TEAM_ID`, `BATTERYKEEPER_NOTARY_*`), never committed. The helper only works in a Developer ID
signed build installed to `/Applications` and approved once in System Settings → General → Login Items.

## Acceptance on the owner's Mac

1. `swift test` passes; a Developer ID signed, notarized build installs and the helper is approved.
2. With AlDente quit, BatteryKeeper sets the limit to 80 %: `pmset -g battlimit` shows the policy and
   `ioreg` shows the battery not charging near 80 % on power. The limit survives quitting BatteryKeeper.
3. Helper: a leased adapter cut makes the battery discharge on power (`InstantAmperage` < 0); killing the app
   restores the adapter within the lease; killing the helper restores it on restart.
4. A shortened calibration cycle (floor a few points below the current charge) runs through every phase and
   restores the limit. A full cycle is left for the owner to run overnight.
5. Statistics record samples and the menu bar icon follows the chosen style and content.
