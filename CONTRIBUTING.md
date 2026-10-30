# Contributing

BatteryKeeper is a personal project, but bug reports and fixes are welcome.

## Issues

- **Bugs:** use the bug report form. Give your Mac model and macOS version, what happened and what you expected; output of `pmset -g batt` and `pmset -g battlimit` helps. A suggested fix is a bonus.
- **Security problems:** report them privately, see [SECURITY.md](SECURITY.md).
- **Feature ideas:** open an issue to discuss it first. BatteryKeeper stays small on purpose, and `docs/design.md` lists its non-goals (such as limits below 80 %, temperature protection and Intel Macs).

## How the project is developed

Most of the code is written by Claude Code agents. `CLAUDE.md` holds the rules they follow; they apply to human contributions too. In short:

- Keep logic in `BatteryKeeperCore` and test it there. `swift test` passes.
- Changes to the adapter switch, PowerUI or the helper cannot be unit tested: say so, and check them on a Mac with `pmset -g batt`, `pmset -g battlimit` and `ioreg -rn AppleSmartBattery`.
- Keep the helper's fail-safe rules in `CLAUDE.md` true. Bump `HelperConstants.protocolVersion` when the XPC protocol changes.
- New UI text needs a Simplified Chinese translation in `scripts/translations-zh-Hans.json`; regenerate the String Catalog with `scripts/make-strings.py`, never edit it by hand.
- No third-party dependencies.
- Comments and docs in English. `CLAUDE.md` asks for Conventional Commits in lowercase.

## Pull requests

Describe the change, list the commands you ran and their results, and say what you checked on a real Mac and on which model and macOS version.
