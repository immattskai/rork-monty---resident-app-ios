# Resident-friendly escalation on informational AI replies

**The problem**

Today, every assistant reply on the resident app shows two technical-looking buttons — Verify and Escalate. Residents aren't reviewers; the Verify control doesn't belong here. And on replies where Monty has already drafted a ticket (Yes / Not now card), surfacing another "escalate" control just duplicates the same path with different wording.

**What I'll change**

- Replace the two pills (Verify + Escalate) under each AI bubble with a single, resident-appropriate control: "This didn't help — talk to a human."
- Only show it on informational AI replies (where there's an answer and an audit id but no ticket proposal and no created ticket).
- Hide it entirely when the assistant produced a `proposedTicket` (the Yes / Not now card is the escalation path for physical issues).
- Tapping it opens a general inquiry ticket prefilled with `I asked: "<question>". Monty said: "<answer>". I still need help.` (category: `general`, priority: `low`, issue_type: `inquiry`) tied to the same `auditId` so the office sees the original AI exchange.
- After success, the badge collapses to a quiet "Sent to your team" row that links into the new ticket.

**What stays the same**

- No layout changes elsewhere — same bubble, same vendor cards, same proposal flow.
- Verify is fully removed from the resident app (web/admin still has it).
- No backend or dark-mode changes.

**How we'll know it worked**

- Informational replies show one resident-friendly button, not two.
- Replies with a ticket proposal show no escalation control.
- Tapping the button creates a general inquiry ticket and confirms inline with a tappable link to it.
