# Herd on a paid developer account

Herd was built on a free account: ad-hoc signed, no root access, and `/usr/bin/top` as the only window into root processes. The paid account (team 5AKJYZ7USP) changes what Herd can be. This note records what changed, what waits, and why.

## Built

| Change | Before | Now |
| --- | --- | --- |
| Root helper (`HerdHelper`, registered with `SMAppService`) | Root processes read from `top` every 10 s, no CPU Power, no disk, about 1 s of CPU each time `top` started | Exact `proc_pid_rusage` counters for every process on every tick; `top` only runs if the helper is off |
| Team signing with hardened runtime | Ad-hoc, a new identity on every build, so macOS forgot permissions like notifications | Signed with Developer ID Application: Tarun Yadgirkar (5AKJYZ7USP), created 2026-10-14, expires 2027-02-01. Herd re-registers the helper by itself when the certificate changes. |
| `scripts/notarize.sh` | No way to share a build | Signs with Developer ID, notarizes, staples, zips |

The helper is read-only on purpose. It accepts a list of process IDs and returns counters. It takes no paths, commands or signals, only answers code signed by this team as `com.tarunyadgirkar.herd`, and exits after a minute without a connection. Quit, pause and force quit stay in the app, where they already work for your own processes.

## Waiting on you

1. **Notary credentials.** `xcrun notarytool store-credentials herd-notary --apple-id <apple id> --team-id 5AKJYZ7USP`, with an app-specific password from account.apple.com.
2. **Notifications.** Herd's notifications are off in System Settings > Notifications, so runaway alerts never appear.

## Not built, and why

| Idea | Why not now |
| --- | --- |
| Network Extension for per-app network | Needs a system extension, a separate entitlement request, and user approval in Privacy settings. `nettop` already attributes traffic per process; the gain is small for the cost. |
| Endpoint Security | Requires an entitlement Apple grants case by case, and Herd watches resource use, not security events. |
| Widgets | WidgetKit needs an app extension, which means moving the build from SwiftPM to an Xcode project. Worth it once the menu bar readout is settled. |
| CloudKit history sync | Herd's history is per Mac by nature; comparing Macs isn't a job anyone has asked Herd to do. |
| Mac App Store | The sandbox would block reading other processes, which is the whole app. Developer ID distribution fits. |
