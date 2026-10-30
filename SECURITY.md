# Security

BatteryKeeper installs a helper that runs as root, so its boundaries matter. The helper is a launch daemon with an XPC interface that switches the power adapter off and on under a time-limited lease, and accepts connections only from the BatteryKeeper app signed by the same team. The app itself is not sandboxed: it reads the SMC and the IORegistry and sets the system charge limit. It makes no network connections.

## Reporting a vulnerability

Please do not open a public issue for a security problem. Report it privately through GitHub: **Security → Report a vulnerability** on this repository ([direct link](https://github.com/nervouna/batterykeeper/security/advisories/new)). Include what you did, what happened, your macOS version and the commit you tested.

You will get an answer within a week. Fixes land on `main`; there are no maintained release branches.

## In scope

- A way for a process other than the signed BatteryKeeper app to talk to the helper
- A way to make the helper do anything other than switch the power adapter, or to run code as root through it
- A way to keep the adapter cut after the lease ends, the app quits, the Mac sleeps or the charge reaches the floor
- Files or settings BatteryKeeper writes that let another user or process change what the helper does

## Out of scope

- Anything that already needs root or an administrator's approval on the Mac
- A build you signed yourself with a different identity, or an ad-hoc build
- The behaviour of macOS's own charge limit, `powerd` or the battery firmware
