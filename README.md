# Herd

A native macOS replacement for Activity Monitor that groups every helper process under the app it belongs to (all of Chrome's renderers under Chrome, Python grouped by script, node by package), with live graphs, power and temperature readings, and alerts for runaway apps.

Runs as your user. An optional root helper (Settings > System processes) reads exact counters for system processes; without it Herd falls back to `top`. No sandbox. See [docs/RETHINK.md](docs/RETHINK.md).

## Requirements

- macOS 15 or later, on Apple Silicon or Intel (the app is a universal binary)
- On Intel Macs, power comes from the SMC (CPU package and graphics), there is no Neural Engine reading, the GPU page shows no clock speeds, and per-app energy is the CPU package power split by CPU time
- Xcode 27 (Swift 6.4)

## Build and run

```bash
swift build                      # debug build
swift test                       # parser and grouping tests
./scripts/build-app.sh           # universal (Apple Silicon + Intel) release build packaged as build/Herd.app
HERD_ARCHS=arm64 ./scripts/build-app.sh  # one architecture only, faster for local testing
./scripts/build-app.sh --install # also copies it to /Applications
./scripts/notarize.sh            # Developer ID build, notarized, packaged as build/Herd.dmg
swiftlint lint                   # cyclomatic complexity stays at 15 or below
```

## Other devices

Herd can show your other Macs, and your iPhone and Watch batteries, over Tailscale (Settings > Other devices). Each Mac that shares has its own key, kept in the login Keychain. Nothing is answered without it.

- **Watch another Mac.** On the Mac to watch, turn on "Share this Mac's stats" and click "Copy key". On this Mac, add its Tailscale name under "Watch Macs" and paste the key into the field beside that name. A Mac without a key shows "Needs key" in the sidebar.
- **Report an iPhone or Watch battery.** Turn on "Show battery reports from my iPhone and Watch" and click "Copy address with key". In Shortcuts on the device, add Get Battery Level, then Get Contents of URL with that address and the battery level on the end. The address looks like `http://100.x.y.z:47787/battery?key=<key>&name=iPhone&level=`. Add `&kind=watch` for a Watch.
- **Reset key** makes a new key. Every Mac and Shortcut that used the old one needs the new one.

## Layout

| Folder | What lives there |
| --- | --- |
| `Sources/Herd/Sampling` | Data sources: libproc/rusage, the root helper client (`top` as fallback), IOReport power and clocks, SMC sensors, battery, GPU, nettop |
| `Sources/HerdHelper` | Root helper daemon: returns process counters over XPC, nothing else |
| `Sources/HerdHelperKit` | XPC protocol and data shared by Herd and the helper |
| `Sources/Herd/Grouping` | Assigns processes to apps, runtimes and standalone tools |
| `Sources/Herd/Remote` | Stats sharing between your Macs and battery reports from your phone, over Tailscale and behind a per-Mac key |
| `Sources/Herd/Store` | Sampling engine actor, observable store, history archive, alerts |
| `Sources/Herd/UI` | SwiftUI views; `UI/Performance` holds the graph pages |
| `Sources/Herd/Actions` | Quit, force quit, pause, efficiency mode, sample |
| `Tests/HerdTests` | Fixture tests for the `top` row parser, bundle detection, and script labeling |

Design tokens (colors, fonts, spacing) live in `Sources/Herd/UI/Theme.swift`. Use them instead of raw values.

The interface is set in Red Hat Text, with Red Hat Display for large numbers. Both ship in `Resources/Fonts` under the SIL Open Font License, and the app bundle registers them through `ATSApplicationFontsPath`.
