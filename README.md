# Herd

A native macOS replacement for Activity Monitor that groups every helper process under the app it belongs to (all of Chrome's renderers under Chrome, Python grouped by script, node by package), with live graphs, power and temperature readings, and alerts for runaway apps.

Runs unprivileged: no root helper, no sandbox.

## Requirements

- macOS 15 or later, Apple Silicon
- Xcode 27 (Swift 6.4)

## Build and run

```bash
swift build                      # debug build
swift test                       # parser and grouping tests
./scripts/build-app.sh           # release build packaged as build/Herd.app
./scripts/build-app.sh --install # also copies it to /Applications
```

## Layout

| Folder | What lives there |
| --- | --- |
| `Sources/Herd/Sampling` | Data sources: libproc/rusage, `top` stream for root processes, IOReport power and clocks, SMC sensors, battery, GPU, nettop |
| `Sources/Herd/Grouping` | Assigns processes to apps, runtimes and standalone tools |
| `Sources/Herd/Store` | Sampling engine actor, observable store, history archive, alerts |
| `Sources/Herd/UI` | SwiftUI views; `UI/Performance` holds the graph pages |
| `Sources/Herd/Actions` | Quit, force quit, pause, efficiency mode, sample |
| `Tests/HerdTests` | Fixture tests for the `top` row parser, bundle detection, and script labeling |

Design tokens (colors, fonts, spacing) live in `Sources/Herd/UI/Theme.swift`. Use them instead of raw values.
