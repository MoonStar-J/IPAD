import Foundation

/// Byte framing keeps split UTF-8 intact. SSE recognizes CR, LF and CRLF.
struct SSEDecoder {
    struct Event { let name: String; let data: Data }
    private var line = Data()
    private var data = Data()
    private var name = ""
    private var afterCR = false
    private var hasData = false
    private var firstLine = true
    mutating func feed(_ byte: UInt8) throws -> Event? {
        if afterCR { afterCR = false; if byte == 10 { return nil } }
        if byte == 10 || byte == 13 {
            afterCR = byte == 13
            defer { line.removeAll(keepingCapacity: true) }
            if firstLine {
                firstLine = false
                if line.starts(with: [0xef, 0xbb, 0xbf]) { line.removeFirst(3) }
            }
            guard let text = String(data: line, encoding: .utf8) else { throw PlanFailure(kind: .protocolError, code: "invalid_utf8") }
            if text.isEmpty {
                guard hasData else { name = ""; return nil }
                if data.last == 10 { data.removeLast() }
                let event = Event(name: name, data: data)
                data.removeAll(keepingCapacity: true); name = ""; hasData = false
                return event
            }
            if text.hasPrefix(":") { return nil }
            let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            var value = parts.count > 1 ? String(parts[1]) : ""
            if value.hasPrefix(" ") { value.removeFirst() }
            if parts[0] == "data" { data.append(contentsOf: value.utf8); data.append(10); hasData = true }
            if parts[0] == "event" { name = value }
            guard data.count <= 4_000_000 else { throw PlanFailure(kind: .protocolError, code: "event_too_large") }
            return nil
        }
        line.append(byte)
        guard line.count <= 4_000_000 else { throw PlanFailure(kind: .protocolError, code: "line_too_large") }
        return nil
    }
}

struct PlanStreamAccumulator {
    private(set) var text = ""
    private(set) var status: AnswerStatus = .streaming
    private(set) var failure: PlanFailure?
    private var seenSequences = Set<Int>()
    mutating func consume(_ event: SSEDecoder.Event) throws {
        guard status == .streaming else { return }
        let payload = String(data: event.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if payload == "" { return }
        if payload == "[DONE]" { end(); return }
        guard let object = (try? JSONSerialization.jsonObject(with: event.data)) as? [String: Any] else { throw PlanFailure(kind: .protocolError, code: "invalid_event") }
        if let sequence = object["sequence_number"] as? Int, !seenSequences.insert(sequence).inserted { return }
        let type = object["type"] as? String ?? event.name
        switch type {
        case "response.output_text.delta": text += object["delta"] as? String ?? ""
        case "response.completed":
            // Final output is canonical; never append it to accumulated deltas.
            if let response = object["response"] as? [String: Any], let output = response["output"] as? [[String: Any]] {
                let final = output.flatMap { $0["content"] as? [[String: Any]] ?? [] }.compactMap { $0["type"] as? String == "output_text" ? $0["text"] as? String : nil }.joined(separator: "\n")
                if !final.isEmpty { text = final }
            }
            status = .completed
        case "response.failed", "error":
            status = .failed
            let body = object["response"] as? [String: Any] ?? object
            failure = PlanFailure.decode(try JSONSerialization.data(withJSONObject: body))
        case "response.incomplete": status = .incomplete
        default: break
        }
        guard text.utf8.count <= 2_000_000 else { throw PlanFailure(kind: .protocolError, code: "answer_too_large") }
    }
    mutating func setFailure(_ failure: PlanFailure) { self.failure = failure }
    mutating func end(cancelled: Bool = false) {
        if status == .streaming { status = cancelled ? .cancelled : .interrupted }
    }
}
