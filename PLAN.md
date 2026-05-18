# Push Ask Monty card below the hero gradient

**Problem**

After the recent home redesign, the "Ask Monty" card is sitting underneath the bottom edge of the hero photo's fade gradient, so the top of the card looks dimmed/cut off.

**Fix**

- Remove the negative top padding that was pulling the Ask Monty card up into the hero fade.
- Nudge the scroll content's top spacer down a touch so the first card clears the hero's fade region cleanly.

No visual changes to the hero itself — just making sure the first card sits fully below the gradient instead of overlapping it.