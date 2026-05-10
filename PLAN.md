# Send conversation history with every Monty chat request

**The fix**

Right now, when you reply "Yes" to Monty's "Would you like me to log a noise complaint?", the app only sends the word "Yes" to the server. The model has no idea what "Yes" refers to, so it either makes up a random ticket (like the ants example) or stalls.

**What changes**

- Every message sent to Monty will now include the recent back-and-forth so the model always knows the context of what's being discussed.
- The history is built from what's already on screen in the chat — the prior user questions and Monty's prior replies — excluding the message currently being sent and any in-progress "thinking" bubbles.
- The user's just-typed message stays in its own field (as today); the history sits alongside it.
- Persisting the user's message to the database now happens before the request goes out, so it can't race ahead of the stream.
- No visible UI changes. No new screens. Same proposal card flow, same vendor cards, same error handling.

**What this fixes**

- "Yes" / "Sure" / "Go ahead" replies now correctly produce a ticket about the original issue (noise, leak, pest, etc.) instead of a hallucinated one.
- Two-step flow works as intended: Monty asks → resident confirms → ticket is drafted from the real prior issue.
- Emergency / explicit "open a ticket" requests still propose immediately (unchanged).