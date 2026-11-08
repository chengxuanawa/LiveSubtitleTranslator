import Foundation

/// 自定义 AI API（OpenAI 兼容 Chat Completions 接口，兼容各类本地/在线模型服务）
@MainActor
final class OpenAICompatibleProvider: TextAIProviding {

    struct Config {
        let endpoint: String
        let apiKey: String
        let model: String
    }

    private let config: Config

    init(config: Config) {
        self.config = config
    }

    func summarize(_ text: String) async throws -> String? {
        let result = try await chat(system: AISummaryPrompt.system, user: text, temperature: 0.1)
        return AITextSanitizer.plainText(result ?? "")
    }

    func polish(_ text: String) async throws -> String? {
        let system = "你是翻译校对助手。把直译改写得更自然、口语化，保持原意。只输出改写后的纯文本，不要解释、引号、星号或任何格式符号。"
        let result = try await chat(system: system, user: text)
        return AITextSanitizer.plainText(result ?? "")
    }

    // MARK: - 私有

    private func chat(system: String, user: String, temperature: Double = 0.3) async throws -> String? {
        guard let url = URL(string: config.endpoint) else { return nil }

        struct ChatMessage: Encodable {
            let role: String
            let content: String
        }
        struct ChatRequestBody: Encodable {
            let model: String
            let messages: [ChatMessage]
            let temperature: Double
        }
        struct ChatResponseBody: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable {
                    let content: String
                }
                let message: Message
            }
            let choices: [Choice]
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        let body = ChatRequestBody(
            model: config.model.isEmpty ? "gpt-4o-mini" : config.model,
            messages: [
                ChatMessage(role: "system", content: system),
                ChatMessage(role: "user", content: user),
            ],
            temperature: temperature
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let decoded = try JSONDecoder().decode(ChatResponseBody.self, from: data)
        let content = decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return (content?.isEmpty ?? true) ? nil : content
    }
}