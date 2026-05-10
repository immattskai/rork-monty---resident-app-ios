# Fix Ask Monty silent failures and align with web contract

- [x] 1. Proposal decoder accepts partial frames (any field present)
- [x] 2. Add `clarifying_question` to `ChatProposedTicket`
- [x] 3. Never delete an empty assistant bubble (friendly fallback)
- [x] 4. Render proposal-only replies with helpful copy
- [x] 5. Cancellation keeps bubble + history with retry
- [x] 6. Real multi-turn session support (`chat_sessions` + `chat_messages` + `sessionId`)
- [x] 7. Wire `ChatActionExtractor` into stream completion
- [x] 8. Sanitize premature "ticket opened" phrasing

## Files touched
- `ios/MontyResidentApp/Services/MontyChatService.swift`
- `ios/MontyResidentApp/Views/Chat/MontyChatView.swift`
- `ios/MontyResidentApp/Services/MontyResidentAppService.swift`
- `ios/MontyResidentApp/Utilities/ChatActions.swift` (wired in; no changes)
