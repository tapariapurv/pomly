<p align="center"><img src="AppStore/icon.png" width="128" alt="Pomly icon"></p>

# Pomly

A calm, native Pomodoro and focus timer for iPhone, iPad, Mac and Apple Watch. Set a time, focus, take a break, carry on.

- **One dial, everywhere.** Drag to set, tap to start. Same look and flow on every device, built in SwiftUI with Liquid Glass.
- **Always in reach.** Live Activities, Dynamic Island, StandBy, Home and Lock Screen widgets, Control Center, a macOS menu bar timer, Siri and Shortcuts ("How much time is left in Pomly?").
- **Rings for real.** AlarmKit alerts break through Silent mode; a local notification is the fallback.
- **Syncs with a code.** Pair devices with a 6-character code. Timer and history stay in step live, with no account to create.
- **Private.** No tracking. Sync uses an anonymous ID; data is readable only by your paired devices.

## Build

Requires Xcode 27.1 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
xcodegen generate
open Pomly.xcodeproj
```

Schemes: `Pomly` (iPhone, iPad, Mac) and `PomlyWatch`. Tests: `xcodebuild -scheme Pomly -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test`.

## Layout

| Folder | What |
|---|---|
| `Pomly/` | App screens (Focus, History, Settings) |
| `Shared/` | Timer engine, model, intents, sync (app, widgets, Watch) |
| `PomlyWidgets/` | Widgets, Live Activity, Control |
| `PomlyWatch/` | Apple Watch app |
| `PomlyTests/` | Swift Testing |

Sync talks to Firebase over REST with no SDK. The web API key in `Shared/Sync.swift` is public by design: database rules restrict every read and write to paired members.
