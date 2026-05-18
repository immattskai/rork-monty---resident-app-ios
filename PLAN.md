# Fix Payments balance showing $500 instead of $5

**The bug**

The charge amount coming back from the server is already in cents (500 = $5.00), but the iOS code is treating it as decimal dollars and multiplying by 100 again — turning $5.00 into $500.00.

**The fix**

Stop multiplying the charge amount by 100 in the four places it happens:

- Payments hero balance
- Pay flow's "full balance" default
- Pay flow's per-charge amount when building the preview/process request
- Per-charge row display in the charge selector

After this, the hero will read $5.00, the preview call will send 500 cents (not 50000), and the receipt totals will be correct.

No design changes, no new screens — just correcting the unit conversion.