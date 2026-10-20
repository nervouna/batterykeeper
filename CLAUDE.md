# BatteryKeeper

BatteryKeeper is a macOS menu bar app for Apple silicon MacBooks: it sets the system charge limit, runs a scheduled
calibration cycle, records battery statistics and draws a configurable menu bar icon. It replaces the parts of
AlDente Pro its owner used. MIT licensed.

Write every commit, issue and PR as if the repository were public: English, no secrets, no personal paths.

## Product scope

See `docs/design.md` (scope, mechanisms, fail-safe) and `docs/research.md` (why the daily limit is left to macOS).

1. Menu bar only (no Dock icon), launches at login (Settings → General).
2. Daily charge limit: the system's own Charge Limit (80, 85, 90, 95 % or off), read and set through the private
   PowerUI framework. The app runs no enforcement loop outside a calibration cycle; powerd enforces the limit.
3. Calibration cycle, every N days from a start hour, or by hand: charge to 100 % → discharge on power to the floor
   → charge to 100 % → hold → discharge to the daily limit → restore the limit.
4. Statistics: daily health, charge and temperature history, live power flow, event log.
5. Menu bar icon: battery, ring or text style; percentage, system power, battery power, temperature and time
   remaining in any combination; badge or colour for the state.
6. Interface in Simplified Chinese with English as the source language.

Non-goals: temperature protection, discharging above the limit in daily use, limits below 80 %, MagSafe LED, Intel
Macs, macOS before 27, Mac App Store distribution.

## Architecture

- Swift 6, SwiftUI + AppKit. Minimum macOS 27. Not sandboxed (IOKit user clients, a private framework), hardened
  runtime on. Bundle ID `io.damao.batterykeeper`; helper label and Mach service `io.damao.batterykeeper.helper`.
- The root `Package.swift` holds everything testable:
  - `BatteryKeeperCore`: pure logic, fully unit tested. `BatterySnapshot` and its parser from the
    `AppleSmartBattery` registry properties, `BatteryStatus`, `CalibrationCycle` (phases, transitions as a function
    of state, snapshot and time, directives), `CycleSchedule`, `AdapterLease` (the helper's rule), `StatusIconModel`,
    `AppSettings` (JSON, a missing or unreadable key takes its default), events and statistics types, `Downsample`.
  - `BatteryKeeperBridge` (C and Objective-C): the AppleSMC user client calls and `BKPowerUI`, a wrapper over the
    private `PowerUISmartChargeClient` loaded with `dlopen`. Every selector is checked before use, so a macOS update
    that changes the private API degrades to "unsupported" instead of crashing.
  - `BatteryKeeperSystem`: `SMCClient`, `BatteryReader` (registry + SMC `TB0T` temperature), `PowerSourceObserver`,
    `ChargeLimitController`, the helper XPC protocol and `HelperClient` (`SMAppService.daemon`), `CodeSigning`,
    `LoginItem`, `SleepAssertion`, `StatsStore` (SQLite, forward-only `user_version`).
  - `BatteryKeeperHelperKit`: the root helper. `HelperService` (lease, owner, every path that ends a lease restores
    the adapter), `SMCAdapterSwitch` (`CHIE`), `HelperDaemon` (XPC listener, signal and sleep hooks).
- `BatteryKeeper.xcodeproj` holds thin targets only: the app (`App/`) and the helper tool (`Helper/`), both
  file-system-synchronized groups. The app embeds the helper in `Contents/MacOS` and
  `LaunchDaemons/io.damao.batterykeeper.helper.plist` in `Contents/Library/LaunchDaemons`. A new target or package
  product means editing `project.pbxproj` by hand; no project generators.
- `App/AppModel.swift` is the hub: a 5 s refresh reads the battery, logs events, stores a sample a minute and a
  health row a day, reads the limit back every 30 s and ticks the cycle. Settings, the running cycle and the end of
  the last cycle live in the app's user defaults.

## Charge control facts (macOS 27, firmware 20457, M1 Pro)

- The SMC charge-inhibit keys (`CH0B`, `CH0C`, `CHTE`) are gone; do not add code that relies on them.
- The daily limit is a `powerd` policy (`pmset -g battlimit`). `setMCLLimit:` sets and switches it on in one call.
  `enableMCL:` resets the limit to 80: never call it after setting a value (see `ChargeLimitController.setLimit`).
  `disableMCL:` switches it off (limit 100).
- `CHIE` (one byte, `0x08` cuts the adapter, `0x00` restores it) is the only adapter switch; writing it needs root.

## Fail-safe rules

- Only the helper writes `CHIE`, and only under a lease the app renews every 30 s (90 s lease, 120 s cap). The helper
  restores the adapter on start, `SIGTERM`, connection end, system sleep, lease expiry and at or below 10 %.
- The app never keeps the adapter cut outside a discharge phase. Quitting restores it.
- Anything unknown (unreadable charge, missing key, unsigned build) means the adapter stays on.
- Both XPC ends require the other to be signed by the same team (`CodeSigning`); nothing hard-codes a team.

## Build, sign, run

- `swift test` runs the unit tests (about a second).
- `scripts/build.sh [debug|release]` builds `build/BatteryKeeper.app` and checks the helper and plist are inside.
- `scripts/install.sh [debug|release]` (default release) builds, replaces `/Applications/BatteryKeeper.app` and
  launches it. It refuses ad-hoc builds: the helper only runs from a team-signed bundle.
- `scripts/release.sh [--skip-notarize]` builds a Developer ID release, checks the app and the helper (hardened
  runtime, timestamp, no `get-task-allow`), notarizes, staples and writes `build/release/BatteryKeeper-<version>.zip`.
- Signing settings are never committed. Scripts source
  `${XDG_CONFIG_HOME:-$HOME/.config}/batterykeeper/signing.env` (`BATTERYKEEPER_CODESIGN_IDENTITY`,
  `BATTERYKEEPER_TEAM_ID`, `BATTERYKEEPER_NOTARY_*`); `BATTERYKEEPER_SIGNING_ENV` overrides the path.
- The helper is registered from the app (Install Helper) and approved once by the user in System Settings → General
  → Login Items. Never approve, reset or edit background items or TCC on the user's behalf.
- A running helper keeps its old binary after an install until launchd restarts it; bump
  `HelperConstants.protocolVersion` whenever the XPC protocol changes so that the app reports an outdated helper.

## Localization

- English source strings in code (`String(localized:)`, SwiftUI literals); Simplified Chinese in
  `scripts/translations-zh-Hans.json`, keyed by the English string.
- `App/Localizable.xcstrings` is generated: run `scripts/build.sh debug` then `scripts/make-strings.py`, which takes
  the keys the compiler extracted and fails on a missing or unused translation. Never edit the catalog by hand.
- Text from `BatteryKeeperCore` and `BatteryKeeperSystem` is not localized: numbers and units only in the menu bar,
  error descriptions passed through as data.

## Debug builds

- Debug builds listen for the distributed notification `io.damao.batterykeeper.debug.show` with the object
  `popover`, `settings`, `statistics`, `close`, `installHelper`, `startCycle`, `cancelCycle`, `statistics:<tab>` (health, history, power, events) or
  `limit:<percent>`,
  so that scripts can open windows (and capture them with `screencapture -l`) and drive the app.
- Shortened test cycles: launch a Debug build with `-testCycleFull 81 -testCycleFloor 77 -testCycleHoldMinutes 1`
  (and optionally `-testCyclePhase <phase>`). A full cycle takes many hours.

## Rules for implementers

- Keep logic in `BatteryKeeperCore` and test it there. `CHIE` writes, PowerUI and the helper cannot be unit tested:
  say so when changing them and verify on the Mac (`pmset -g batt`, `pmset -g battlimit`, `ioreg -rn
  AppleSmartBattery`, and the SMC value of `CHIE`).
- Do not add third-party dependencies.
- Comments and docs in English. Conventional Commits, lowercase.
