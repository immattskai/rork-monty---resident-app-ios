import Foundation

/// A structured action emitted by Monty AI inside its streamed reply.
nonisolated struct ChatAction: Sendable {
    let name: String
    let payload: [String: Any]

    /// Raw substring (within the original message) that produced this action.
    /// Used to strip the JSON from the rendered text.
    let span: Range<String.Index>
}

nonisolated enum ChatActionExtractor {
    /// Returns the cleaned message text (with all action JSON removed) and the
    /// list of actions found inside `text`. Tolerant of three formats:
    ///
    /// 1. Fenced ```json ... ``` blocks
    /// 2. Fenced ``` ... ``` blocks where the body parses as JSON
    /// 3. Bare `{ "action": "...", ... }` objects in prose
    ///
    /// Also strips leading bare `json` lines that some models emit before a
    /// fence-less object.
    static func extract(from text: String) -> (cleaned: String, actions: [ChatAction]) {
        var actions: [ChatAction] = []
        var spansToRemove: [Range<String.Index>] = []

        // 1) Fenced blocks: ```[lang]\n ... \n```
        let fencePattern = #"```([a-zA-Z0-9]*)\n([\s\S]*?)```"#
        if let regex = try? NSRegularExpression(pattern: fencePattern) {
            let ns = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            for m in matches where m.numberOfRanges >= 3 {
                let bodyRange = m.range(at: 2)
                let body = ns.substring(with: bodyRange)
                if let parsed = parseAction(body) {
                    if let r = Range(m.range, in: text) {
                        actions.append(ChatAction(name: parsed.name, payload: parsed.payload, span: r))
                        spansToRemove.append(r)
                    }
                }
            }
        }

        // 2) Bare top-level JSON objects with an "action" key. We use a
        //    balanced-brace scan so we don't choke on nested `{}`.
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            if chars[i] == "{" {
                var depth = 0
                var j = i
                var inString = false
                var escape = false
                while j < chars.count {
                    let c = chars[j]
                    if inString {
                        if escape { escape = false }
                        else if c == "\\" { escape = true }
                        else if c == "\"" { inString = false }
                    } else {
                        if c == "\"" { inString = true }
                        else if c == "{" { depth += 1 }
                        else if c == "}" {
                            depth -= 1
                            if depth == 0 { break }
                        }
                    }
                    j += 1
                }
                if depth == 0 && j < chars.count {
                    let candidate = String(chars[i...j])
                    if let parsed = parseAction(candidate) {
                        let start = text.index(text.startIndex, offsetBy: i)
                        let end = text.index(text.startIndex, offsetBy: j + 1)
                        let r = start..<end
                        // Skip if already covered by a fence span.
                        let alreadyCovered = spansToRemove.contains { $0.overlaps(r) }
                        if !alreadyCovered {
                            actions.append(ChatAction(name: parsed.name, payload: parsed.payload, span: r))
                            spansToRemove.append(r)
                        }
                    }
                    i = j + 1
                    continue
                }
            }
            i += 1
        }

        // Build the cleaned text by removing spans (longest first to keep
        // indices stable), then collapse stray "json" labels and excess
        // whitespace left behind.
        var cleaned = text
        let sorted = spansToRemove.sorted { $0.lowerBound > $1.lowerBound }
        for r in sorted {
            cleaned.removeSubrange(r)
        }

        // Drop a stray bare `json` line that often precedes a fence-less object.
        if let bareJsonRegex = try? NSRegularExpression(pattern: #"(?m)^\s*json\s*$"#) {
            let ns = cleaned as NSString
            cleaned = bareJsonRegex.stringByReplacingMatches(
                in: cleaned,
                range: NSRange(location: 0, length: ns.length),
                withTemplate: ""
            )
        }
        // Collapse 3+ newlines that the removals may have produced.
        if let blankRegex = try? NSRegularExpression(pattern: #"\n{3,}"#) {
            let ns = cleaned as NSString
            cleaned = blankRegex.stringByReplacingMatches(
                in: cleaned,
                range: NSRange(location: 0, length: ns.length),
                withTemplate: "\n\n"
            )
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        return (cleaned, actions)
    }

    private static func parseAction(_ raw: String) -> (name: String, payload: [String: Any])? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let name = obj["action"] as? String, !name.isEmpty else { return nil }
        return (name, obj)
    }
}
