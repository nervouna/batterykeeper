# BatteryKeeper

A macOS menu bar app for Apple silicon MacBooks that keeps the battery healthy:

- **Charge limit**: sets the system's own Charge Limit (80–100 %), enforced by macOS even when BatteryKeeper is not
  running, plus "Charge to Full Now".
- **Calibration cycle**: every few weeks, or on demand, charges to 100 %, discharges while plugged in to a floor,
  charges to 100 % again, holds, then returns to the daily limit.
- **Statistics**: battery health over months, charge and temperature history, live power flow and an event log.
- **Menu bar icon**: battery, ring or text, with any of percentage, system power, battery power, temperature and
  time remaining.

The interface is in Simplified Chinese.

Requirements: macOS 27 or later on an Apple silicon MacBook.

## How it works

macOS 26.4 added a built-in charge limit, and macOS 27 firmware removed the SMC keys third-party tools used to stop
charging. BatteryKeeper therefore leaves the daily limit to macOS (`pmset -g battlimit` shows it) and only takes over
during a calibration cycle. To discharge while plugged in, a small privileged helper cuts the power adapter under a
lease that the app renews every 30 seconds; the helper restores the adapter when the lease runs out, when the app
quits or crashes, before the Mac sleeps and when the charge falls to 10 %. See [docs/research.md](docs/research.md)
and [docs/design.md](docs/design.md).

## Install

Calibration cycles need the helper: open Settings and click Install, then allow BatteryKeeper in System Settings →
General → Login Items. The charge limit, statistics and menu bar icon work without it.

## Development

```sh
swift test                  # unit tests
scripts/build.sh debug      # build/BatteryKeeper.app
scripts/install.sh          # signed release build into /Applications
scripts/release.sh          # notarized zip in build/release
```

Signing settings come from `~/.config/batterykeeper/signing.env` and are never committed. See [CLAUDE.md](CLAUDE.md)
for the architecture and the rules.

## License

MIT
