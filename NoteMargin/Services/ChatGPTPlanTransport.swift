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
        guard (200..<300).contains(response.statusCode) else {
            var error = Data()
            for try await byte in bytes { if error.count < 65_536 { error.append(byte) } else { break } }
            throw PlanFailure.decode(error, status: response.statusCode, requestID: response.value(forHTTPHeaderField: "x-request-id"))
        }
        guard response.mimeType == "text/event-stream" else { throw PlanFailure(kind: .protocolError, code: "not_sse") }
        var parser = SSEDecoder(), result = PlanStreamAccumulator()
        var lastUpdate = Date.distantPast
        do {
            for try await byte in bytes {
                try Task.checkCancellation()
                if let event = try parser.feed(byte) {
                    try result.consume(event)
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
            throw error
        }
    }
}
