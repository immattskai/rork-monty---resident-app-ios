//
//  MontyResidentAppTests.swift
//  MontyResidentAppTests
//
//  Created by Rork on May 5, 2026.
//

import Foundation
import Testing
@testable import MontyResidentApp

struct MontyResidentAppTests {

    // MARK: - decodeProposedTicket

    @Test func decodeProposedTicket_acceptsFullDraftWithoutClarifyingQuestion() async throws {
        let dict: [String: Any] = [
            "title": "Bugs in room",
            "description": "Resident reports bugs in their room.",
            "issue_type": "pest control",
            "category": "general",
            "priority": "medium",
        ]
        let pt = try #require(decodeProposedTicket(dict))
        #expect(pt.title == "Bugs in room")
        #expect(pt.description == "Resident reports bugs in their room.")
        #expect(pt.issue_type == "pest control")
        #expect(pt.category == "general")
        #expect(pt.priority == "medium")
        #expect(pt.clarifying_question == nil)
        #expect(pt.hasDraftTicket == true)
    }

    @Test func decodeProposedTicket_acceptsClarifyingOnly() async throws {
        let dict: [String: Any] = ["clarifying_question": "Where are the bugs?"]
        let pt = try #require(decodeProposedTicket(dict))
        #expect(pt.clarifying_question == "Where are the bugs?")
        #expect(pt.title == nil)
        #expect(pt.hasDraftTicket == false)
    }

    @Test func decodeProposedTicket_rejectsEmpty() {
        #expect(decodeProposedTicket([:]) == nil)
        #expect(decodeProposedTicket(["title": "", "description": ""]) == nil)
    }

    // MARK: - parseSSEFrame

    @Test func parseSSEFrame_complexityMeta() {
        let events = parseSSEFrame(#"data: {"complexity":"simple"}"#)
        #expect(events.count == 1)
        if case .meta(let c) = events.first { #expect(c == "simple") } else { Issue.record("expected .meta") }
    }

    @Test func parseSSEFrame_delta() {
        let events = parseSSEFrame(#"data: {"choices":[{"delta":{"content":"hi"}}]}"#)
        #expect(events.count == 1)
        if case .delta(let s) = events.first { #expect(s == "hi") } else { Issue.record("expected .delta") }
    }

    @Test func parseSSEFrame_proposedTicketBareKey() {
        let payload = #"data: {"proposedTicket":{"title":"Bugs in room","description":"Resident reports bugs in their room.","issue_type":"pest control","category":"general","priority":"medium"}}"#
        let events = parseSSEFrame(payload)
        #expect(events.count == 1)
        if case .proposedTicket(let pt) = events.first {
            #expect(pt.title == "Bugs in room")
            #expect(pt.issue_type == "pest control")
        } else {
            Issue.record("expected .proposedTicket")
        }
    }

    @Test func parseSSEFrame_auditId() {
        let events = parseSSEFrame(#"data: {"auditId":"abc"}"#)
        #expect(events.count == 1)
        if case .auditId(let id) = events.first { #expect(id == "abc") } else { Issue.record("expected .auditId") }
    }

    @Test func parseSSEFrame_done() {
        let events = parseSSEFrame("data: [DONE]")
        #expect(events.count == 1)
        if case .done = events.first {} else { Issue.record("expected .done") }
    }

    @Test func parseSSEFrame_ignoresCommentAndEventLines() {
        let frame = ": keepalive\nevent: ignored\ndata: [DONE]"
        let events = parseSSEFrame(frame)
        #expect(events.count == 1)
        if case .done = events.first {} else { Issue.record("expected .done") }
    }

    // MARK: - SSEFrameBuffer: end-to-end regression

    /// Drives the buffered SSE parser with the exact frame sequence the
    /// chat-with-ai server emits, split across two reads with the split
    /// landing mid-frame on purpose. Asserts every event is yielded in order
    /// and that the assistant content reassembles exactly.
    @Test func sseBuffer_handlesSplitReads_endToEnd() throws {
        let part1 = "Sounds like a pest issue \u{2014} "
        let part2 = "I've drafted a ticket. "
        let part3 = "Confirm below."
        let expectedContent = part1 + part2 + part3

        let frames: [String] = [
            #"data: {"complexity":"simple"}"#,
            "data: {\"choices\":[{\"delta\":{\"content\":\(jsonString(part1))}}]}",
            "data: {\"choices\":[{\"delta\":{\"content\":\(jsonString(part2))}}]}",
            "data: {\"choices\":[{\"delta\":{\"content\":\(jsonString(part3))}}]}",
            #"data: {"proposedTicket":{"title":"Bugs in room","description":"Resident reports bugs in their room.","issue_type":"pest control","category":"general","priority":"medium"}}"#,
            #"data: {"auditId":"abc"}"#,
            "data: [DONE]",
        ]
        let wire = frames.joined(separator: "\n\n") + "\n\n"
        let wireData = wire.data(using: .utf8)!

        // Split the wire bytes in two reads, with the split landing
        // deliberately mid-frame (inside the second delta payload).
        let splitPoint = wireData.firstRange(of: Data("drafted".utf8))!.lowerBound + 3
        let chunk1 = wireData.subdata(in: 0..<splitPoint)
        let chunk2 = wireData.subdata(in: splitPoint..<wireData.count)

        var buffer = SSEFrameBuffer()
        var collected: [ChatStreamEvent] = []
        for frame in buffer.append(chunk1) {
            collected.append(contentsOf: parseSSEFrame(frame))
        }
        for frame in buffer.append(chunk2) {
            collected.append(contentsOf: parseSSEFrame(frame))
        }
        if let trailing = buffer.flush() {
            collected.append(contentsOf: parseSSEFrame(trailing))
        }

        // Reassemble the visible bubble content from delta events.
        var content = ""
        var proposal: ChatProposedTicket?
        var audit: String?
        var sawDone = false
        for ev in collected {
            switch ev {
            case .delta(let s): content += s
            case .proposedTicket(let pt): proposal = pt
            case .auditId(let id): audit = id
            case .done: sawDone = true
            case .meta: break
            }
        }

        #expect(content == expectedContent)
        let pt = try #require(proposal)
        #expect(pt.title == "Bugs in room")
        #expect(pt.issue_type == "pest control")
        #expect(audit == "abc")
        #expect(sawDone == true)

        // Verify the no-invented-copy invariant: nothing the client could
        // synthesize should appear anywhere in the collected content.
        #expect(!content.contains("I didn't catch that"))
    }

    @Test func sseBuffer_handlesCRLFSeparator() {
        let wire = "data: {\"auditId\":\"x\"}\r\n\r\ndata: [DONE]\r\n\r\n"
        var buffer = SSEFrameBuffer()
        let frames = buffer.append(wire.data(using: .utf8)!)
        #expect(frames.count == 2)
        let evs = frames.flatMap { parseSSEFrame($0) }
        #expect(evs.contains { if case .auditId(let id) = $0 { return id == "x" } else { return false } })
        #expect(evs.contains { if case .done = $0 { return true } else { return false } })
    }

    // MARK: - Helpers

    private func jsonString(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s], options: [])
        // ["..."] → "..."
        let str = String(data: data, encoding: .utf8)!
        return String(str.dropFirst().dropLast())
    }
}
