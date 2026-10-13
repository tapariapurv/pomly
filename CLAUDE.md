# Pomly — project rules

Native iOS Pomodoro / focus timer. SwiftUI, iOS 26+ (built with the iOS 27 SDK), iPhone incl. iPhone Duo.

## 0. Token efficiency (top priority, applies to every agent and subagent)
- The cheapest correct path wins. Batch independent tool calls. Never re-read, re-fetch or re-derive what is already known.
- Docs: fetch only the page you need, filtered to the relevant lines (see 2–3). Record the takeaway here so it's never fetched again.
- Builds: quiet, errors only (see Commands). Screenshots only to judge visuals, at reduced scale.
- Small targeted edits, not rewrites. No speculative features, abstractions or files.
- Replies: terse. No feature tours or long recaps.
- Don't spawn subagents unless the user asks.

## 1. Project
- XcodeGen: edit `project.yml`, then `xcodegen generate`. Never hand-edit `Pomly.xcodeproj` (it's generated and gitignored).
- `Pomly/` app only · `Shared/` compiled into the app + widget extension · `PomlyWidgets/` widgets, control, Live Activity · `PomlyTests/` Swift Testing.
- Bundle `com.purvt.pomly`, App Group `group.com.purvt.pomly`. Free dev account: no FamilyControls, no iCloud.
- Timer = AlarmKit (date-based). `TimerEngine` is the single source of truth; the fallback is a local notification.

## 2. Design rules
1. Native first: system components, SF Symbols, Liquid Glass (`glassEffect`, `.glass`/`.glassProminent`, `GlassEffectContainer`) on controls and navigation only. Never on content. No third-party packages.
2. Before building or redesigning a section, read its HIG page. Rule headlines only:
   `curl -sL https://sosumi.ai/design/human-interface-guidelines/<slug> | grep -E '^\*\*' | head -20`
   Read the full page only if a headline needs detail. Add a 1-line takeaway under **HIG notes**.
3. API doubt → grep the SDK interface first (free, exact):
   `grep -n "<symbol>" $(xcrun --sdk iphonesimulator --show-sdk-path)/System/Library/Frameworks/<FW>.framework/Modules/<FW>.swiftmodule/arm64-apple-ios-simulator.swiftinterface`
   Still unclear → Apple docs as markdown: `curl -sL https://sosumi.ai/documentation/<framework>/<symbol> | head -80`.
4. Layout: size classes, safe areas, no fixed widths. Regular width (iPhone Duo inner display, landscape) shows the dial and Today side by side. `reservedRegions(kind: .division)` (iOS 27.1) keeps content off the fold.
5. Defaults stay simple. Power options live under Settings › Advanced.
6. Accessibility is part of done: Dynamic Type, VoiceOver labels and values, Reduce Motion, 44 pt targets, 4.5:1 contrast.
7. Strings are localizable (String Catalog). Use title case for buttons and titles (HIG Writing).

## HIG page map
| Area | Slugs |
|---|---|
| Focus screen | designing-for-ios, layout, materials, color, dark-mode, typography, buttons, gauges, motion, playing-haptics |
| History | charting-data, charts, lists-and-tables |
| Settings | settings, toggles, pickers, steppers, segmented-controls |
| Navigation | tab-bars |
| System surfaces | widgets, live-activities, controls, app-shortcuts, notifications, managing-notifications, always-on |
| iPhone Duo | designing-for-iphone-duo |
| Polish / launch | accessibility, app-icons, privacy, ratings-and-reviews, launching, writing |

## HIG notes (read already, don't refetch)
- materials: no glass in the content layer; use it sparingly; vibrant colors on materials.
- buttons: one prominent style for the most likely action; distinguish by style, not size; a destructive action is never primary.
- tab-bars: navigation only, never actions; always labelled; SF Symbols.
- settings: minimal settings and great defaults; task options live in context, not in Settings.
- notifications: concise; no app name in the text; handle the foreground case; offer useful actions.
- live-activities: glanceable, match the app look in light and dark, readable text, concentric margins, no logo container.
- controls: descriptive symbol, brand tint, update the state after the action, placeholder for variable values.
- charting-data: simple, accessible, add descriptive text (totals and averages).
- ratings-and-reviews: ask only after engagement, never mid-task, use the system prompt.
- app-icons: centered primary content, clear edges, filled overlapping shapes, no text.
- always-on: dim nonessential content, keep the layout stable.
- designing-for-iphone-duo: the outer display puts tab and tool bars on the side automatically. Compact width outside, regular inside. Expand the layout instead of reinventing it, keep elements off the fold, prefer small adjustments. Preview poses in the Xcode Device Hub.

## Gotchas (learned the hard way)
- Live Activity / widget views: never `.fixedSize()` a `Text(timerInterval:)` and never `.frame(maxHeight: .infinity)` inside Dynamic Island regions; both crash the system renderer. Give timers a fixed width slot.
- App-requested Live Activities must stay under 4 KB of attributes, and iOS only displays `AlarmAttributes` that a real AlarmKit alarm backs. That's why the fallback uses its own `PomlyActivityAttributes`.
- Simulator: AlarmKit permission is auto-denied, so the fallback path is what you test there. If processes die during launch (watchdog 0x8BADF00D), check `uptime` load and run `xcrun simctl runtime dyld_shared_cache update --all`.
- Never call `UNUserNotificationCenter.removePendingNotificationRequests` on the main thread (it's synchronous XPC).
- Preference plist reads from the shell lag behind the app (cfprefsd caching). Verify UI state by screenshot, not by the plist.
- Cheap screenshots: `xcrun simctl io booted screenshot x.png && sips -Z 420 x.png`, cropped with `sips -c H W --cropOffset Y X`.

## Commands
- `xcodegen generate`
- Build: `xcodebuild -scheme Pomly -destination 'generic/platform=iOS Simulator' -quiet build 2>&1 | grep -E "error:|warning: .*/(Pomly|Shared|PomlyWidgets)/" | head -30`
- Test: `xcodebuild -scheme Pomly -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet test 2>&1 | tail -20`

## Deferred
- App blocking (needs a paid account + the Family Controls entitlement): `.individual` auth, `FamilyActivityPicker` for allowed apps, `ManagedSettingsStore` shield applied on start and cleared on end, plus a DeviceActivity monitor extension as a safety net.
- iCloud sync: switch the `ModelContainer` config to CloudKit. The model is already CloudKit-compatible.

## Sync (Firebase, REST only, no SDK)
- Project `pomly-43c42` (macOS Chrome, account Purv). Anonymous Auth on. RTDB `https://pomly-43c42-default-rtdb.firebaseio.com`, rules: `codes/$code` (pairing codes, 10 min) and `spaces/$space/{members,state,sessions}`, members only. Web API key lives in `Shared/Sync.swift`.
- Always use the user's **macOS** Chrome (Claude in Chrome `select_browser`), never the Windows one.
