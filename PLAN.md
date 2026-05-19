# Redesign the "Make a payment" screen with proper full vs. split allocation

## What's wrong today

The screen lets you pick "Full balance" but still forces you to pick a single charge with a radio button to apply it to. That's confusing and contradicts the action ("I'm paying everything").

## New behavior

**Full balance mode (default)**

- No radio buttons. The charge list becomes a clean read-only summary showing every open charge with its amount and due date.
- A subtle line under the list reads "Applied to all 3 charges · $1,105.00 total".
- The payment will be allocated to every open charge automatically (oldest first), so all of them clear in one tap.

**Custom amount mode**

- Each charge row gets its own small amount field on the right (replacing the radio).
- The total of those fields must match the custom amount entered above — a live "Allocated $X of $Y" indicator shows progress and turns green when balanced.
- A quick "Split evenly" / "Apply to oldest" shortcut row sits above the list to fill the fields with one tap.
- Continue button stays disabled until the allocation matches.

## Design refresh

- Replace the two boxy "Full balance / Custom" chips with a single segmented control that visually feels native and animated.
- Balance card stays, but the giant number gets a soft animated count-up when the mode flips between full and custom.
- "APPLIES TO" section header gets a small inline hint ("All charges" or "Split across") so the mode is always obvious.
- Each charge row gets a colored category dot (assessment / monthly / one-off) plus an overdue pill in red when applicable, so the list reads at a glance.
- Continue button at the bottom shows the total being paid plus a tiny "across N charges" subtitle.
- Tighter padding, smoother card shadows, haptic tick when toggling modes or balancing the split.

## Screens touched

- The "Make a payment" sheet (first step of the pay flow) — everything above happens here. Method, review, and success steps are unchanged.

