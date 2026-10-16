# App Store listing: Pomly

Character counts are exact. Apple indexes the **name, subtitle and keyword field** (and on macOS, the in-app purchase names). The keyword field never repeats a word that's already in the name or subtitle, because Apple combines them.

## iOS / iPadOS / watchOS (one listing)

| Field | Text | Chars |
|---|---|---|
| Name | Pomly: Pomodoro Focus Timer | 27/30 |
| Subtitle | Study, deep work & break timer | 30/30 |
| Keywords | productivity,adhd,tomato,flow,concentration,habit,goal,streak,widget,countdown,clock,tracker,blocker | 100/100 |
| Category | Productivity (primary) · Education (secondary) | |
| Age rating | 4+ | |

**Promotional text** (170, editable without review)
> Focus, and leave the distractions out. Pomly blocks YouTube, X and Reddit in Safari and Chrome while your timer runs. Widgets, Mac menu bar and Apple Watch, all in sync. (169)

**Description**
```
Pomly is the calm Pomodoro timer: drag the dial, tap Start, focus. Take a break when it rings.
Live Activities, Dynamic Island, widgets, Apple Watch and a Mac menu bar timer keep it one glance away.
Free, private, and no account: devices pair with a 6-character code.

BLOCK DISTRACTING SITES
• Pomly Focus for Safari and Chrome blocks YouTube, X, Reddit and any site you add while you focus
• Breaks are free: sites open again the moment the session ends
• Need one anyway? Solve a quick sum to open it for five minutes
• Pairs with your timer, so starting on your iPhone or Watch blocks them on your Mac

FOCUS, SIMPLY
• Drag around the dial to set 1–120 minutes, or tap 15 · 25 · 45 · 60
• Alarms ring through Silent mode and Focus, with "Take a Break" right on the alert
• Label what you're working on: Study, Reading, Deep Work
• Ambient sound while you focus: white noise, brown noise or rain, alongside your music
• Full-screen minimal timer in black or white, portrait or landscape

ALWAYS IN REACH
• Live Activity on the Lock Screen and in the Dynamic Island, in three styles
• Home Screen widgets that start sessions, plus Lock Screen and StandBy
• Control Center and Action Button toggle
• Siri and Shortcuts: "Start a focus in Pomly", "How much time is left in Pomly?"
• Focus filter: your Work Focus starts a session and ends it when the Focus turns off

EVERY DEVICE
• iPhone, iPad and iPhone Duo layouts
• Apple Watch app with Digital Crown and watch-face complications
• Mac: menu bar timer, drag down from the icon to set a time, floating mini timer, global shortcuts
• Instant sync between your devices with a pairing code

PROGRESS WITHOUT PRESSURE
• Daily goal ring, week and month charts, streaks
• Long breaks every few sessions, auto-start options, five color themes, light and dark

PRIVATE BY DESIGN
No ads, no tracking, no analytics, no sign-up. Sync is optional and anonymous.
```

**What's New (1.0)**
> Hello, Pomly. Drag, focus, rest, repeat on iPhone, iPad, Mac and Apple Watch.

**Support URL:** https://tapariapurv.github.io/pomly/support.html
**Marketing URL:** https://tapariapurv.github.io/pomly/
**Privacy Policy URL:** https://tapariapurv.github.io/pomly/privacy.html

## Mac App Store (separate keyword field)

| Field | Text | Chars |
|---|---|---|
| Name | Pomly: Pomodoro Focus Timer | 27/30 |
| Subtitle | Menu bar study & break clock | 28/30 |
| Keywords | productivity,adhd,tomato,flow,concentration,habit,goal,streak,widget,menubar,countdown,blocker,exam | 99/100 |
| Category | Productivity | |

Lead the Mac description with the menu bar and the blocker: "A Pomodoro timer that lives in your menu bar. Press the icon and drag down to pick a length, name it, and focus. Pomly Focus for Safari keeps distracting sites closed until it rings."

## Screenshots (order matters: the first 3 show in search)

**6.9" iPhone (1320×2868):**
1. "Drag. Focus. Rest." The dial in dark mode, mid-session.
2. "Always one glance away." Lock Screen Live Activity and Dynamic Island.
3. "Widgets that start sessions." The large widget with the presets.
4. "Rings through Silent mode." The alarm with "Take a Break".
5. "See your streak." History with the week chart.
6. "Every device, in sync." iPhone, iPad, Mac and Watch with the pairing code.

**13" iPad:** the side-by-side dial and Today panel, then History and Settings.
**Mac:** the menu bar drag line ("25 min"), the Safari blocked page ("Stay Focused"), the mini timer floating over work, then the main window.
**Watch:** the edge-to-edge dial, then a complication on a face.

**App Preview (15–30 s):** use the 9:16 cut of `promo/` (drag the dial → Live Activity → widget → Watch → Mac menu bar → sync).

## App Privacy ("nutrition label")

- **Data Not Linked to You** (only when the user turns on Sync):
  - *Identifiers → User ID*: an anonymous Firebase ID, for App Functionality.
  - *Usage Data → Product Interaction*: timer state, for App Functionality.
  - *User Content → Other User Content*: focus sessions (times and labels), for App Functionality.
- **Tracking:** none. No third-party SDKs, analytics or ads.
- **Encryption:** HTTPS only, so `ITSAppUsesNonExemptEncryption = NO`.

## In-app events (later)

- "Exam Season Focus Sprint": 7 days of 4 sessions a day.
- "Deep Work Week", for Productivity featuring.

## Review notes

Sync is optional and uses no account: open Settings › Sync Devices and enter the code shown on another device. AlarmKit permission is asked on the first Start.
