# Safe performance pass — smoother scrolling and faster taps with no visual changes

Status: shipped the safe wins. Held off on the items flagged as having any visual risk per the "safe wins only" scope.

**Done**

- [x] **Cache photos in memory.** Bumped `URLCache.shared` to 64 MB RAM / 256 MB disk at app init so `AsyncImage` reuses hero, amenity, package, post, and avatar photos across screen visits.
- [x] **Reuse formatters.** Added a cached currency `NumberFormatter` (keyed by code+digits) and a shared `yyyy-MM-dd` `DateFormatter` in `Fmt`. Home's two ad-hoc whole-dollar formatters now route through `Fmt.currencyWhole`.
- [x] **Prepare haptics.** New `Haptics` helper with prepared light/medium/soft generators. Replaced every `UIImpactFeedbackGenerator(style: .light).impactOccurred()` site across Home, Tickets, Packages, Payments, Amenities, Community, Documents, Guests, Contacts, Chip, AddGuestSheet, plus the medium tap in `NotificationOnboardingView`.
- [x] **Avoid redundant work on Home reload.** `HomeViewModel.load` now skips if the same unit was loaded within the last 30s. Pull-to-refresh forces a full refetch.

**Held (would risk visual change — say the word and I'll do them)**

- [ ] Lighter Home compositing (swap `.mask` for overlay gradient).
- [ ] Stabilize a couple of index-keyed `ForEach`s.
- [ ] Cache expensive Home computed properties.
- [ ] Trim redundant overlapping card shadows.

**Verified**

- [x] iOS build passes.
