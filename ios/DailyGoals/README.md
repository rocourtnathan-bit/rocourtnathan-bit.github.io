# Daily Goals (iOS)

A native SwiftUI habit/goal checklist. iOS 17+, SwiftData, local notifications.

- Add goals with an emoji and a "finish by" time
- Check them off on the Today tab, with a progress ring
- Streaks (current and best) and a 7-day view on the Progress tab
- If a goal isn't done by its deadline, you get a notification
- All data stays on your phone

## Run it on your iPhone

Needs a Mac with Xcode 15 or newer, and a free Apple ID.

```bash
brew install xcodegen
cd ios/DailyGoals
xcodegen generate
open DailyGoals.xcodeproj
```

In Xcode:

1. Click the **DailyGoals** project, then the **DailyGoals** target, then **Signing & Capabilities**.
2. Tick **Automatically manage signing** and pick your Apple ID as the Team.
3. If the bundle ID is taken, change `com.nathan.dailygoals` to something unique.
4. Plug in your iPhone, pick it at the top, and press Run. On the phone, go to Settings, General, VPN & Device Management and trust your developer profile.

With a free Apple ID the app expires after 7 days and you re-run it from Xcode.
A paid developer account ($99/yr) removes that and lets you use TestFlight or the App Store.

## How the reminders work

iOS can't run code at the deadline to check whether you finished. So the app
schedules one-off notifications for the next few days and rebuilds them whenever
goals change or the app opens. If a goal is done today, today's reminder is skipped.
If you don't open the app for about a week, the reminders run out.

## No XcodeGen?

Create a new iOS App in Xcode (SwiftUI, Storage: None), delete its default files,
and drag in everything from the inner `DailyGoals/` folder.
