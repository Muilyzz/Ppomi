// A thin client for an OpenAI-compatible endpoint (api.openai.com or a Vercel AI Gateway). Only what the settings screen
// needs: is the key accepted, which models are there, how much budget is left.
import Foundation

struct LLMClient {
    let baseURL: URL
    let apiKey: String

    enum Error: Swift.Error, LocalizedError {
        case http(Int, String)      // status, body prefix
        case network(String)
        case badResponse
        var errorDescription: String? {
            switch self {
            case .http(401, _): return "401: 키가 거부됨"
            case .http(403, _): return "403: 권한 없음"
            case .http(404, _): return "404: 주소를 찾을 수 없음"
            case .http(429, _): return "429: 요청 한도 초과"
            case .http(let code, let body): return "\(code): \(body)"
            case .network(let why): return "네트워크 오류: \(why)"
            case .badResponse: return "응답을 해석할 수 없음"
            }
        }
    }

    /// GET {baseURL}/models → data[].id, sorted.
    func listModels() async throws -> [String] {
        let (data, status) = try await get("models")
        guard (200..<300).contains(status) else { throw Error.http(status, Self.prefix(data)) }
        guard let models = Self.parseModels(data) else { throw Error.badResponse }
        return models
    }

    /// GET {baseURL}/credits — a Vercel AI Gateway thing ({"balance": "95.50", ...}). Anything else (404, another shape)
    /// is not an error: the balance is nil and the caller gets the raw body prefix to show or ignore.
    func credits() async throws -> (balance: Double?, raw: String) {
        let (data, status) = try await get("credits")
        let raw = Self.prefix(data)
        guard (200..<300).contains(status) else { return (nil, "HTTP \(status) \(raw)") }
        return (Self.parseBalance(data), raw)
    }

    // MARK: - Parsing (static so a test can feed bytes without a network)

    static func parseModels(_ data: Data) -> [String]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["data"] as? [[String: Any]] else { return nil }
        return list.compactMap { $0["id"] as? String }.sorted()
    }

    /// The first "balance" found at the top level or one level down, as a number or a numeric string.
    static func parseBalance(_ data: Data) -> Double? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let candidates = [obj] + obj.values.compactMap { $0 as? [String: Any] }
        for dict in candidates {
            if let n = dict["balance"] as? NSNumber { return n.doubleValue }
            if let s = dict["balance"] as? String, let n = Double(s) { return n }
        }
        return nil
    }

    // MARK: - Transport

    private func get(_ path: String) async throws -> (Data, Int) {
        var req = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: 15)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            throw Error.network(error.localizedDescription)
        }
    }

    private static func prefix(_ data: Data) -> String {
        String(String(decoding: data, as: UTF8.self).prefix(160))
    }
}
