# Stop tickets refresh from showing a "cancelled" error screen

**What's happening**

When you pull down to refresh the Tickets list, the previous request sometimes gets cancelled (normal behavior — a second request supersedes the first). The screen treats that cancellation as a real failure and replaces your entire ticket list with the red "Something went wrong · cancelled · Try again" screen.

**The fix**

- Ignore cancellation as an error — it isn't one. Your tickets stay on screen and the spinner just goes away.
- Keep showing real errors (no network, server down, etc.) exactly as before.
- Also avoid flashing the skeleton list during a pull-to-refresh; the existing tickets should stay visible while the spinner runs, and only update when fresh data arrives.

**Result**

Pull-to-refresh on Tickets behaves like every other refresh in the app — list stays put, spinner shows, list updates. No more accidental error screen.