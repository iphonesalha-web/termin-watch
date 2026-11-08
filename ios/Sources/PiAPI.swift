import Foundation

// MARK: - نماذج الردود

struct DeviceInfo: Decodable {
    var temp_c: Double?
    var uptime_s: Int?
    var load: Double?
    var mem_used_pct: Int?
    var disk_used_pct: Int?
}

struct StatusResponse: Decodable {
    var service: String
    var cutoff: String?
    var telegram: Bool?
    var last_check: String?
    var ok: Bool?
    var error: String?
    var total: Int?
    var earliest: String?
    var upcoming: [String: [String]]?
    var device: DeviceInfo?
    var now: String?
}

struct LogResponse: Decodable {
    var lines: [String]
}

struct ActionResponse: Decodable {
    var ok: Bool?
    var message: String?
    var error: String?
    var service: String?
    var cutoff: String?
}

// MARK: - الأخطاء

enum PiError: LocalizedError {
    case notConfigured
    case unauthorized
    case server(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "أدخل عنوان الـ Pi وكلمة السر في تبويب الإعدادات."
        case .unauthorized: return "كلمة السر غير صحيحة."
        case .server(let m): return m
        case .network(let m): return "تعذّر الاتصال بالـ Pi: \(m)"
        }
    }
}

// MARK: - العميل

struct PiAPI {
    let base: URL
    let token: String

    static func fromDefaults() -> PiAPI? {
        let d = UserDefaults.standard
        var host = (d.string(forKey: "host") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let token = (d.string(forKey: "token") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !token.isEmpty else { return nil }
        if !host.lowercased().hasPrefix("http") { host = "http://" + host }
        guard let url = URL(string: host) else { return nil }
        return PiAPI(base: url, token: token)
    }

    private func makeRequest(_ method: String, _ path: String, body: [String: String]?) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: base)?.absoluteURL else {
            throw PiError.server("عنوان غير صالح")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 12
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body = body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    func call<T: Decodable>(_ type: T.Type, method: String = "GET", path: String,
                            body: [String: String]? = nil) async throws -> T {
        let req = try makeRequest(method, path, body: body)
        var result: (Data, URLResponse)
        do {
            result = try await URLSession.shared.data(for: req)
        } catch {
            throw PiError.network(error.localizedDescription)
        }
        let (data, resp) = result
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw PiError.unauthorized }
        if !(200..<300).contains(code) {
            if let a = try? JSONDecoder().decode(ActionResponse.self, from: data) {
                throw PiError.server(a.error ?? a.message ?? "خطأ \(code)")
            }
            throw PiError.server("خطأ من الخادم (\(code))")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw PiError.server("رد غير متوقع من الـ Pi")
        }
    }
}
