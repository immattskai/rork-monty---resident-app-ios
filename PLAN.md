# Fix Ask Monty silent drop: diagnostics, buffered SSE, no invented copy

Land the fix in the exact order you specified. No fictional-shape parsing, no invented assistant copy.

### 1. Diagnostics first
- [x] Log a 200-char preview of every raw SSE frame in DEBUG.
- [x] Log `Array(json.keys)` for every parsed frame in DEBUG.
- [x] Log a one-line summary on stream end (bytes, frames, deltas, sawProposal, sawAudit, sawDone).

### 2. Stop inventing assistant copy
- [x] Deleted the `"I didn't catch that…"` fallback.
- [x] Deleted the `"Request was cancelled…"` invented string.
- [x] Empty-stream + cancelled paths now surface a real error bubble (`"Couldn't reach Monty — tap to retry."`) with the existing Retry action.
- [x] Grep confirmed no other invented assistant copy in the iOS repo.

### 3. Replace `bytes.lines` with a real SSE parser
- [x] New `SSEFrameBuffer` accumulates bytes and splits on `\n\n` / `\r\n\r\n`.
- [x] `parseSSEFrame` joins multi-`data:` lines per spec and yields events.
- [x] JSON parse failures on fully-assembled frames are logged loudly in DEBUG.
- [x] `[DONE]` handling unchanged.

### 4. Verify `decodeProposedTicket`
- [x] Unit test for full-draft payload (no clarifying_question).
- [x] Unit test for clarifying-only payload.
- [x] Unit test for rejection of empty payloads.

### 5. Regression test for the full stream
- [x] Hand-built byte stream covering complexity meta, three deltas, proposedTicket, auditId, [DONE].
- [x] Split into two reads with the split landing mid-frame.
- [x] Asserts content matches exactly, proposal/audit/done all present, no invented copy leaks.
- [x] Extra test for CRLF separator.

### 6. Explicitly NOT done
- No wrapped envelopes, no `event:` line handling, no JSON fallback path, no fictional shape branches.

### Validation
- [x] `runChecks ios` passed.
- [ ] Re-send "Bugs in my room" and share the DEBUG frame log so we can confirm which of (A)/(B)/(C) was actually happening.
