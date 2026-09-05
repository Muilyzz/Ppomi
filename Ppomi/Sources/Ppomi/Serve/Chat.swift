// One chat completion on an OpenAI-compatible endpoint (Tools' categorize / advise) and the ToolSpec the voice session and
// MCP server publish. Key: the Keychain (settings screen), else OPENAI_API_KEY from the environment / .env.
import Foundation

struct ToolSpec {
    let name, description: String
    var params: [String: (type: String, description: String?)] = [:]
    var required: [String] = []

    var json: [String: Any] {
        ["type": "function", "function": ["name": name, "description": description,
            "parameters": ["type": "object", "required": required,
                           "properties": params.mapValues { v -> [String: String] in var d = ["type": v.type]; if let s = v.description { d["description"] = s }; return d }]]]
    }
}

enum Chat {
    struct Failure: LocalizedError, CustomStringConvertible { let description: String; var errorDescription: String? { description } }

    static var apiKey: String? { Keychain.apiKey() ?? AppSettings.env("OPENAI_API_KEY") }
    static var model: String { AppSettings.env("OPENAI_MODEL") ?? AppSettings.model }

    private static func post(_ body: [String: Any]) throws -> [String: Any] {
        guard let key = apiKey, !key.isEmpty else { throw Failure(description: "API 키가 없습니다: 설정에서 키를 넣거나 .env에 OPENAI_API_KEY") }
        var req = URLRequest(url: URL(string: AppSettings.baseURL)!.appendingPathComponent("chat/completions"), timeoutInterval: 180)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let sem = DispatchSemaphore(value: 0)
        var out: (Data?, URLResponse?, Error?) = (nil, nil, nil)
        URLSession.shared.dataTask(with: req) { out = ($0, $1, $2); sem.signal() }.resume()
        sem.wait()
        if let e = out.2 { throw Failure(description: "network: \(e.localizedDescription)") }
        let code = (out.1 as? HTTPURLResponse)?.statusCode ?? 0, data = out.0 ?? Data()
        guard (200..<300).contains(code) else { throw Failure(description: "OpenAI \(code): \(String(decoding: data.prefix(300), as: UTF8.self))") }
        guard let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure(description: "bad response") }
        return d
    }

    private static func usageLine(_ model: String, _ tokens: (Int, Int)) -> String { "\(model) 입력 \(tokens.0) / 출력 \(tokens.1) 토큰" }

    /// system + user → (text, usage line). Full reasoning (the weekly review wants it).
    static func complete(system: String, user: String, model: String? = nil, maxTokens: Int = 2000) throws -> (String, String) {
        let m = model ?? self.model
        let d = try post(["model": m, "messages": [["role": "system", "content": system], ["role": "user", "content": user]], "max_completion_tokens": maxTokens])
        let u = d["usage"] as? [String: Any] ?? [:]
        let text = (((d["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String) ?? ""
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), usageLine(m, (u["prompt_tokens"] as? Int ?? 0, u["completion_tokens"] as? Int ?? 0)))
    }
}
