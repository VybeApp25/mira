import Foundation

// GPT-4o chat completions — used when user explicitly requests GPT/ChatGPT,
// or as model-choice alternative alongside Claude.
final class OpenAIService {

    private let apiKey: String
    private let baseURL = URL(string: "https://api.openai.com/v1/chat/completions")!

    init(apiKey: String) { self.apiKey = apiKey }

    // MARK: - Public

    func chat(
        prompt:     String,
        system:     String  = MiraPrompts.system,
        model:      String  = "gpt-4o",
        maxTokens:  Int     = 600
    ) async throws -> String {
        struct Msg: Encodable   { let role: String; let content: String }
        struct Body: Encodable  {
            let model: String; let max_tokens: Int
            let messages: [Msg]
        }
        struct Choice: Decodable {
            struct Msg: Decodable { let content: String? }
            let message: Msg
        }
        struct Resp: Decodable { let choices: [Choice] }

        let messages: [Msg] = [
            Msg(role: "system", content: system),
            Msg(role: "user",   content: prompt),
        ]
        let body = Body(model: model, max_tokens: maxTokens, messages: messages)

        var req = URLRequest(url: baseURL)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        req.timeoutInterval = max(60, Double(maxTokens) / 40)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw MiraError.api("OpenAI: \(msg)")
        }
        let decoded = try JSONDecoder().decode(Resp.self, from: data)
        return decoded.choices.first?.message.content ?? ""
    }

    // Convenience: returns empty string on failure instead of throwing
    func chatOrEmpty(prompt: String, system: String = MiraPrompts.system,
                     model: String = "gpt-4o", maxTokens: Int = 600) async -> String {
        (try? await chat(prompt: prompt, system: system,
                         model: model, maxTokens: maxTokens)) ?? ""
    }

    // MARK: - Static helpers

    static var effectiveKey: String {
        let saved = UserDefaults.standard.string(forKey: "mira_openai_key") ?? ""
        return saved.isEmpty ? AppSecrets.openAIKey : saved
    }

    static var isConfigured: Bool { !effectiveKey.isEmpty }
}
