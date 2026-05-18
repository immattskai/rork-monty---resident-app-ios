# Apply all 4 home performance wins

All four optimizations to make Home feel smoother, with no visual changes.

**What I'll do**

- **Replace the scroll mask with a gradient overlay.** The current top-fade uses a full-screen mask, which forces an expensive offscreen render every frame while scrolling. I'll swap it for a lightweight gradient overlay that the GPU can draw on its fast path. You should feel noticeably smoother scrolling, especially on older devices.

- **Stabilize index-keyed lists.** A few lists on Home key their items by position instead of identity. When data shifts or reloads, this causes images to re-fetch and animations to glitch. I'll switch them to stable IDs so rows stay put across refreshes.

- **Cache Home tile metrics.** Small win — pre-compute the tile heights and grid measurements once instead of re-deriving them as part of every layout pass.

- **Trim overlapping card shadows.** Several tiles stack their own drop shadow on top of the same card background. I'll consolidate to a single shadow per card so the GPU isn't drawing the same blur twice. Scrolling past dense rows of cards will feel lighter.

**What won't change**

- No visual redesign — same layout, same colors, same card look.
- Same Payments tall card, same 4-up bottom row, same announcements section.
- Pull-to-refresh and realtime announcements keep working exactly as today.
