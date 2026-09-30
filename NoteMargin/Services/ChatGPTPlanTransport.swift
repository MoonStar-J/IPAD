import Foundation

struct ChatGPTPlanTransport {
    static func stream(request body: PlanRequest, token: String, http: PlanHTTP = .shared, update: @escaping @MainActor (PlanStreamAccumulator) -> Void) async throws -> PlanStreamAccumulator {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"; request.httpBody = try JSONEncoder().encode(body)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await http.session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse else { throw PlanFailure(kind: .protocolError, code: "missing_http") }
        func diagnostic(_ failure: PlanFailure) -> PlanFailure {
            failure.withResponse(status: response.statusCode, requestID: response.value(forHTTPHeaderField: "x-request-id"), contentType: response.mimeType)
        }
        var iterator = bytes.makeAsyncIterator()
        var parser = SSEDecoder(), result = PlanStreamAccumulator()
        var lastUpdate = Date.distantPast
        do {
            guard (200..<300).contains(response.statusCode) else {
                var error = Data()
                while error.count < 65_536, let byte = try await iterator.next() { try Task.checkCancellation(); error.append(byte) }
                throw diagnostic(PlanFailure.decode(error, status: response.statusCode))
            }
            // Some responses reach iPad with a generic or missing Content-Type.
            // Recognize actual SSE framing before rejecting the response. Never
            // replay the POST, accept HTML as a reply, or turn JSON into a fake
            // response.completed event.
            var prefix = Data()
            while Self.framing(prefix) == .pending, prefix.count < 4096, let byte = try await iterator.next() {
                try Task.checkCancellation(); prefix.append(byte)
            }
            guard Self.framing(prefix) == .sse else {
                var data = prefix
                while data.count < 65_536, let byte = try await iterator.next() { try Task.checkCancellation(); data.append(byte) }
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                if let object, object["error"] != nil || object["code"] != nil || object["type"] as? String == "error" {
                    throw diagnostic(PlanFailure.decode(data, status: response.statusCode))
                }
                throw diagnostic(PlanFailure(kind: .protocolError, code: object == nil ? "not_sse" : "non_streaming_json"))
            }
            // A valid first line can arrive split across any network boundary.
            for byte in prefix { if let event = try parser.feed(byte) { try result.consume(event) } }
            while let byte = try await iterator.next() {
                try Task.checkCancellation()
                if let event = try parser.feed(byte) {
                    try result.consume(event)
                    if let failure = result.failure { result.setFailure(diagnostic(failure)) }
                    if Date().timeIntervalSince(lastUpdate) >= 0.08 || result.status != .streaming {
                        await update(result); lastUpdate = Date()
                    }
                    if result.status != .streaming { return result }
                }
            }
            try Task.checkCancellation()
            result.end(); await update(result); return result
        } catch {
            result.end(cancelled: Task.isCancelled || error is CancellationError)
            await update(result)
            if let failure = error as? PlanFailure { throw diagnostic(failure) }
            throw error
        }
    }

    private enum Framing { case pending, sse, other }
    private static func framing(_ data: Data) -> Framing {
        var bytes = Array(data)
        let bom: [UInt8] = [0xef, 0xbb, 0xbf]
        if !bytes.isEmpty, bom.starts(with: bytes) { return .pending }
        if bytes.starts(with: bom) { bytes.removeFirst(3) }
        while bytes.first == 10 || bytes.first == 13 { bytes.removeFirst() }
        guard !bytes.isEmpty else { return .pending }
        let fields = [":", "data:", "event:", "id:", "retry:"]
        if fields.contains(where: { bytes.starts(with: Array($0.utf8)) }) { return .sse }
        if fields.contains(where: { Array($0.utf8).starts(with: bytes) }) { return .pending }
        return .other
    }
}
