# Keep Monty's stream alive past [DONE] so the ticket proposal renders

**The problem**

When you ask Monty about something like "ants in my room," the server sometimes sends its `[DONE]` marker *before* the actual ticket proposal. Right now the app stops listening as soon as it sees `[DONE]`, so the proposal arrives after we've already hung up — the bubble shows nothing and feels like Monty froze.

**What I'll change**

- Make the chat keep reading from the server until it actually closes the connection, even after `[DONE]` is seen. Any ticket proposal or audit info that arrives in the tail will now be picked up.
- Add detailed behind-the-scenes logging for the tool-call frames (function name, argument chunks, whether there's text vs. only a tool call) so if this ever silently drops again we'll see exactly where in the stream.
- Log a final summary that reflects whether a proposal/audit landed even after `[DONE]`.

**What stays the same**

- No design, copy, layout, or dark-mode changes.
- No backend changes.
- Ticket creation, vendor cards, verify/escalate, and the proposal card all keep working exactly as today.

**How we'll know it worked**

- Asking "there are ants in my room" now shows the ticket proposal card.
- The debug summary reports `proposal=true`.
- No fallback/error bubble appears.

