# Ask Monty / ticket-creation overhaul to match new server contract

Update iOS so all ticket creation goes through `create-ticket-from-chat`, and the
chat stream understands the new `proposedTicket` + `auditId` SSE meta events.
Kill the old direct-insert + fire-and-forget triage path.

## Tasks

- [x] `MontyChatService.stream`: parse new SSE meta frames
  - Yield `.proposedTicket(ChatProposedTicket)` and `.auditId(String)` cases
  - Remove `.ticket` case (backend no longer emits it)
  - Make sure trailing flush before `[DONE]` still routes meta JSON correctly
  - Map errors to friendly messages (401/403/404/429/5xx/network)
- [x] `MontyResidentAppService`
  - Add `createTicketFromChat(...)` that hits `/functions/v1/create-ticket-from-chat`
    and returns `{ ticket, recommendedVendors, triageIntent }`
  - Add `contactVendorForTicket(ticketId, vendorId)`
  - Add `fetchVendorOutreachStatus(ticketId)`
  - Add `verifyAIResponse(auditId)` and `escalateAIResponse(auditId, reason)` RPCs
  - Remove (deprecate) the legacy direct-insert `createTicketFromChat` body
- [x] `MontyChatView` / `MontyChatViewModel`
  - Drop `ChatActionExtractor` `create_ticket` / `recommend_vendors` paths
  - Render `TicketProposalCard` ("Open a ticket?" + Yes / Not now)
  - On confirm → call `createTicketFromChat` → swap to `TicketCreatedCard`
    with vendor cards + outreach prompt
  - Show "AI answer" badge with Verify / Escalate
  - Friendly in-bubble error with Retry
  - Use brand-safe chat bubble colors (mid-blue user / surface assistant)
- [x] `TicketDetailView`
  - Render vendor cards + outreach prompt at top of conversation when
    `ai_recommended_vendor_ids.length > 0`, gated on `vendor_outreach_status`
  - Stop showing "no messages yet" empty state — backend pre-seeds
- [x] Validate with `runChecks`

## What stays the same

- Existing `TicketsListView`, ticket models, vendor cards visual style.
- `NewTicketView` legacy flow (still used outside chat for explicit ticket creation).
- Dark/light theme tokens.
