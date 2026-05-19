# Redesign the Board Tasks Kanban

## What changes on the Tasks tab

**Layout**
- Keep the four columns (Backlog → To Do → In Progress → Done) but make the board feel intentional instead of half-empty.
- Columns snap one-at-a-time as you swipe left/right (paging), so you always land on a whole column instead of mid-scroll.
- A slim page indicator below the header shows which column you're on (●○○○) and the column name + count is shown in a clear pill at the top of each page.
- Each column fills the available width with comfortable side gutters — no more cramped 280-wide cards with a sliver of the next column peeking in.

**Empty columns**
- No more big dashed boxes. When a column has no tasks, just a single muted line of text ("Nothing in Backlog") sits quietly under the header, with the blue + button remaining the obvious way to add one.

**Card style (compact rows)**
- Each card becomes a tight one-line row: small colored priority dot on the left, task title in the middle (truncates with ellipsis), due date on the right.
- Overdue due dates turn red. Tasks with no due date simply omit the date.
- Tap a row → existing detail sheet. Long-press → existing action menu (move, change priority, delete).
- Cards stack vertically with subtle dividers; the whole column scrolls vertically when there are many.

**Header polish**
- Column header shows the column name + a small count chip (e.g. "TO DO · 3") and a thin colored accent line underneath in the column's status color (gray / blue / amber / green).

**Micro-interactions**
- Light haptic on column-snap, on long-press, and on status change.
- Cards fade/slide in on first load.
- Moving a task to another column animates it leaving the current list.

**Floating + button**
- Unchanged position (bottom-right), slightly tighter shadow so it doesn't bloom on the dark background.

No changes to data, filters, the create sheet, or the detail sheet — purely a visual + interaction overhaul of the board itself.