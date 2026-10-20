# Charge control on Apple Silicon, macOS 27 (research, 2026-10-20)

Findings that decide whether BatteryKeeper is worth building, and what it could do.

## Test machine

- MacBookPro18,1 (M1 Pro), macOS 27.0.1 (26A434), system firmware 20457.1.29.
- AlDente Pro 1.39.4 installed and running, limit 80 %, sailing 5 %, heat protection at 35 °C.

## macOS has a built-in charge limit

Since macOS Tahoe 26.4, Apple silicon Macs have a native **Charge Limit**
([Apple support 102338](https://support.apple.com/en-us/102338)):

- System Settings → Battery → (i) next to Charging. Range 80–100 %.
- The Mac charges to within a few points of the limit, then stops. If the charge falls more than 5 % while
  on power, it charges back up to the limit (built-in hysteresis, equivalent to AlDente "sailing 5").
- "Charge to Full Now" in the battery status menu is a one-off override to 100 %.
- The battery menu shows "Charged to N% Limit".
- macOS still charges to 100 % occasionally to recalibrate its state-of-charge estimate.

The limit is a `ChargeCtrlPolicy` held by `powerd` (persisted in
`/Library/Preferences/com.apple.powerd.charging.plist`) and set through `PowerUIAgent`.
`pmset -g battlimit` lists the active policies. On the test machine it shows a `manualChargeLimit` policy
with `chargeSocLimitSoc = 79`, `chargeSocLimitDrain = 1`, owned by `PowerUIAgent`.

Through `PowerUISmartChargeClient`, `setMCLLimit:` sets the limit and switches it on; `enableMCL:` resets it to the
default 80 %; `disableMCL:` removes the policy. None of these needs an entitlement (verified from a Developer ID app
and an unsigned binary).

No app runs to enforce it: it holds across sleep, app quits and crashes, which is the fail-safe property
the v0.1 brief asks for, for free.

## The SMC charge-inhibit keys are gone

Read-only probe of the AppleSMC user client on the test machine (key info + value, no writes):

| Key | Meaning on earlier firmware | macOS 27 firmware 20457 |
| --- | --- | --- |
| `CH0B`, `CH0C` | charge inhibit (pre-macOS 15 firmware) | absent |
| `CHTE` | charge inhibit (macOS 15/26 firmware) | absent |
| `CHWA` | fixed 80 % limit (early Apple silicon) | absent |
| `BCLM` | charge level max (Intel) | absent |
| `CH0I`, `CH0J`, `CH0K` | adapter disable (older firmware) | absent |
| `CHIE` | adapter disable (newer firmware) | present, `hex_`, 1 byte, writable |
| `ACLC` | MagSafe LED control | present, `ui8`, writable |

The batt README corroborates this: on firmware `20457.0.125.0.2`+ (macOS 27 beta 4 and later) the
direct charge keys are gated behind the private entitlement `com.apple.private.iokit.soc-limit`
(`kIOReturnNotPrivileged` even for root), and the native limit is "driven through PowerUIAgent" and
"enforced by powerd".

Consequences for a third-party tool on this machine:

1. **Hold at a limit ≥ 80 %**: only through the native policy. Third parties reach it through the private
   `PowerUI.framework` (`PowerUISmartChargeClient`, manual charge limit, 80–100 only). AlDente 1.39.4 does
   exactly this (`PowerUIBackend` in its binary), which is why the active policy is owned by `PowerUIAgent`.
2. **Limit < 80 %, heat protection, discharge while plugged in**: only by toggling `CHIE` (cut the adapter
   so the Mac runs from the battery). batt calls this "adapter mode". It is a cycle, not a hold: the battery
   discharges to the lower bound, then charges back up. It is enforced only while the controlling process is
   awake, cutting wall power during clamshell sleep can put the Mac to sleep, and if the controller dies with
   the adapter cut the Mac drains until something re-enables it. It needs a root helper.

## Verified on the test machine (2026-10-21)

- Writing `CHIE = 0x08` as root (the BatteryKeeper helper) cuts the adapter: the Mac runs from the battery while
  plugged in. The registry then reports `ExternalConnected = No` and `ExternalChargeCapable = No`, while
  `AdapterDetails` still lists the adapter (90 W). Writing `0x00` restores it immediately.
- `setMCLLimit:` changes the `powerd` policy at once (`pmset -g battlimit`), and the policy survives quitting
  AlDente and BatteryKeeper.
- Killing the app makes the helper restore the adapter within a second (the XPC connection ends); killing the
  helper makes launchd restart it, and the restarted helper restores the adapter before the app cuts it again.

## Existing open-source tools

| Project | License | Mechanism on macOS 27 |
| --- | --- | --- |
| [charlie0129/batt](https://github.com/charlie0129/batt) | GPL-2.0 | native limit (≥ 80), or adapter mode for any limit |
| [rurza/BatFi](https://github.com/rurza/BatFi) | MIT | not checked in detail |
| [mhaeuser/Battery-Toolkit](https://github.com/mhaeuser/Battery-Toolkit) | BSD-3-Clause, archived | SMC keys; broken on macOS 27 per reports |
| AlDente (closed source; public repo is issues and releases) | proprietary | PowerUI manual charge limit + SMC adapter key |

No code from any of them is needed or used. The AppleSMC user client protocol (selector 2, commands
read key / write key / key info / key at index) is long-documented public behaviour.

## Conclusion

For the v0.1 brief (80 % limit, hysteresis, charge-to-100 override, status in the menu bar, fail-safe), the
built-in Charge Limit already does all of it, more robustly than any app can, because powerd and the
firmware enforce it with no helper process. The one thing a self-built app could add on macOS 27 is the
adapter-mode family (limit below 80 %, heat protection, discharge while plugged in), which is fragile and
only works while the app is awake.
