# Fix Home "No balance" tile to match real pending charges

**The bug**

The Payments tile on the home screen reads from a cached balance table (and an older "outstanding balance" field). Your real $5.00 charge lives in the pending charges list — the same place the Payments screen reads from. So the home tile shows "No balance" while the Payments screen correctly shows $5.00.

**The fix**

- Make the home Payments tile read the balance from the same source as the Payments screen: the sum of pending charges.
- The cached balance becomes a fallback only — if there are no pending charges, then fall back to the cache (so other installs that rely on it keep working).
- After this change, the tile will say **$5.00 · Current balance** for your account, and flip to **No balance · You're all caught up** only when there are genuinely no pending charges.

No visual changes — same card, same colors, same layout. Just the number it displays.