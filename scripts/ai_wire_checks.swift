import Foundation

@main struct WireChecks {
    static func main() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
        let messages = [AIRequestMessage(role: "user", text: "First"), AIRequestMessage(role: "assistant", text: "Answer"), AIRequestMessage(role: "user", text: "Follow-up")]
        var count = 0
        func check(_ value: Bool) { precondition(value); count += 1 }
        func fails(_ action: () throws -> Void) { do { try action(); preconditionFailure("Expected rejection") } catch { count += 1 } }
        for provider in AIProvider.allCases {
            let request = try AIClient.makeRequest(provider: provider, model: provider.defaultModel, apiKey: "test-placeholder", instructions: "Project scope", messages: messages, imageData: png, regionText: "PDF selection")
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            check(request.httpMethod == "POST")
            check(request.url!.scheme == "https" && request.url!.query == nil)
            if provider == .openAI {
                check(body["store"] as? Bool == false)
                check(body["instructions"] as? String == "Project scope")
                let input = body["input"] as! [[String: Any]]
                let image = (input[0]["content"] as! [[String: Any]])[1]
                check((image["image_url"] as? String)?.hasPrefix("data:image/png;base64,") == true)
                check(input.count == 4 && input[3]["content"] as? String == "Follow-up")
                check(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-placeholder")
            } else {
                let contents = body["contents"] as! [[String: Any]]
                check(contents.map { $0["role"] as! String } == ["user", "model", "user"])
                let parts = contents[0]["parts"] as! [[String: Any]]
                check((parts[1]["inlineData"] as? [String: String])?["mimeType"] == "image/png")
                check(body["systemInstruction"] != nil)
                check(request.value(forHTTPHeaderField: "x-goog-api-key") == "test-placeholder")
            }
            for code in [401, 403, 429, 503] { fails { _ = try AIClient.responseText(data: Data(), statusCode: code, provider: provider) } }
            fails { _ = try AIClient.responseText(data: Data("{}".utf8), statusCode: 200, provider: provider) }
            fails { _ = try AIClient.normalizedModel("bad/path?key=secret", provider: provider) }
        }
        let openAI = Data(#"{"status":"completed","output":[{"type":"reasoning","content":[{"type":"output_text","text":"hidden"}]},{"type":"message","content":[{"type":"output_text","text":"Visible answer"}]}]}"#.utf8)
        check(try AIClient.responseText(data: openAI, statusCode: 200, provider: .openAI) == "Visible answer")
        let gemini = Data(#"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"thought":true,"text":"hidden"},{"text":"Visible answer"}]}}]}"#.utf8)
        check(try AIClient.responseText(data: gemini, statusCode: 200, provider: .gemini) == "Visible answer")
        fails { _ = try AIClient.responseText(data: Data(#"{"status":"incomplete"}"#.utf8), statusCode: 200, provider: .openAI) }
        fails { _ = try AIClient.responseText(data: Data(#"{"promptFeedback":{"blockReason":"SAFETY"}}"#.utf8), statusCode: 200, provider: .gemini) }
        fails { _ = try AIClient.makeRequest(provider: .gemini, model: "gemini-2.5-flash", apiKey: "placeholder", instructions: "", messages: [AIRequestMessage(role: "assistant", text: "Bad first turn")], imageData: png, regionText: "") }
        let cancelled = Task { () throws -> String in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await AIClient.send(provider: .openAI, model: "gpt-5-mini", apiKey: "placeholder", instructions: "", messages: messages, imageData: png, regionText: "")
        }
        do { _ = try await cancelled.value; preconditionFailure("Expected cancellation") } catch is CancellationError { count += 1 }
        print("PASS: \(count) API request/response and cancellation checks (no network requests)")
    }
}
