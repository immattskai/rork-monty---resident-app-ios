import Foundation

nonisolated enum SupabaseError: LocalizedError {
    case badURL
    case http(status: Int, message: String)
    case decoding(String)
    case auth(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "Invalid URL"
        case .http(_, let m): return m
        case .decoding(let m): return "Couldn't read response (\(m))"
        case .auth(let m): return m
        case .network(let m): return m
        }
    }
}

nonisolated struct AuthResponse: Codable, Sendable {
    var access_token: String
    var refresh_token: String
    var expires_at: Int?
    var expires_in: Int?
    var token_type: String?
    var user: AuthUser?
}

nonisolated struct AuthUser: Codable, Sendable {
    var id: String
    var email: String?
}

nonisolated struct AuthError: Codable, Sendable {
    var error: String?
    var error_description: String?
    var msg: String?
    var message: String?
    var code: String?
}

@MainActor
@Observable
final class SupabaseAPI {
    static let shared = SupabaseAPI()

    var session: SupabaseSession? {
        didSet { SessionStore.save(session) }
    }

    private let urlSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        return URLSession(configuration: cfg)
    }()

    private var refreshTask: Task<SupabaseSession, Error>?

    init() {
        self.session = SessionStore.load()
    }

    private var baseURL: URL {
        URL(string: SupabaseConfig.url)!
    }

    var isSignedIn: Bool { session != nil }

    // MARK: - Auth

    func signIn(email: String, password: String) async throws -> SupabaseSession {
        var req = URLRequest(url: baseURL.appendingPathComponent("/auth/v1/token"))
        req.url = req.url?.appending(queryItems: [URLQueryItem(name: "grant_type", value: "password")])
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "email": email, "password": password
        ])
        let auth: AuthResponse = try await performAuth(req)
        let s = sessionFrom(auth)
        self.session = s
        return s
    }

    func signOut() async {
        if let token = session?.access_token {
            var req = URLRequest(url: baseURL.appendingPathComponent("/auth/v1/logout"))
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
            _ = try? await urlSession.data(for: req)
        }
        self.session = nil
        ActiveUnitStore.save(nil)
    }

    func refreshIfNeeded() async throws {
        guard let s = session else { return }
        guard s.isExpired else { return }
        _ = try await refresh(refreshToken: s.refresh_token)
    }

    private func refresh(refreshToken: String) async throws -> SupabaseSession {
        if let t = refreshTask { return try await t.value }
        let t = Task<SupabaseSession, Error> { [weak self] in
            guard let self else { throw SupabaseError.auth("Client gone") }
            var req = URLRequest(url: self.baseURL.appendingPathComponent("/auth/v1/token"))
            req.url = req.url?.appending(queryItems: [URLQueryItem(name: "grant_type", value: "refresh_token")])
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken])
            let auth: AuthResponse = try await self.performAuth(req)
            let s = self.sessionFrom(auth)
            self.session = s
            return s
        }
        refreshTask = t
        defer { refreshTask = nil }
        return try await t.value
    }

    private func sessionFrom(_ r: AuthResponse) -> SupabaseSession {
        let exp: Int? = r.expires_at ?? r.expires_in.map { Int(Date().timeIntervalSince1970) + $0 }
        // Preserve the previously known user_id/email if the refresh response
        // doesn't include the user object — otherwise every uid-filtered query
        // would silently return [] after a token refresh.
        let prior = self.session
        return SupabaseSession(
            access_token: r.access_token,
            refresh_token: r.refresh_token,
            expires_at: exp,
            token_type: r.token_type,
            user_id: r.user?.id ?? prior?.user_id,
            email: r.user?.email ?? prior?.email
        )
    }

    private func performAuth<T: Decodable>(_ req: URLRequest) async throws -> T {
        do {
            let (data, resp) = try await urlSession.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw SupabaseError.network("No response") }
            if !(200...299).contains(http.statusCode) {
                let err = try? JSONDecoder().decode(AuthError.self, from: data)
                let msg = err?.error_description ?? err?.msg ?? err?.message ?? err?.error ?? "Sign in failed"
                throw SupabaseError.auth(msg)
            }
            return try JSONDecoder().decode(T.self, from: data)
        } catch let e as SupabaseError { throw e }
        catch { throw SupabaseError.network(error.localizedDescription) }
    }

    // MARK: - REST (PostgREST)

    func from(_ table: String) -> Query {
        Query(api: self, table: table)
    }

    /// Insert one row and return the inserted record.
    func insert<Body: Encodable, T: Decodable>(
        into table: String,
        body: Body,
        returning: T.Type
    ) async throws -> T {
        guard let url = URL(string: SupabaseConfig.url + "/rest/v1/" + table) else {
            throw SupabaseError.badURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("return=representation", forHTTPHeaderField: "Prefer")
        let encoder = JSONEncoder()
        req.httpBody = try encoder.encode(body)
        let data = try await performData(req)
        do {
            let rows = try JSONDecoder().decode([T].self, from: data)
            guard let first = rows.first else {
                throw SupabaseError.decoding("Empty insert response")
            }
            return first
        } catch {
            throw SupabaseError.decoding(String(describing: error))
        }
    }

    /// PATCH a single row matched by `id`. Returns the updated row.
    @discardableResult
    func update<Body: Encodable, T: Decodable>(
        table: String,
        id: String,
        body: Body,
        returning: T.Type
    ) async throws -> T {
        guard var comps = URLComponents(string: SupabaseConfig.url + "/rest/v1/" + table) else {
            throw SupabaseError.badURL
        }
        comps.queryItems = [URLQueryItem(name: "id", value: "eq.\(id)")]
        guard let url = comps.url else { throw SupabaseError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("return=representation", forHTTPHeaderField: "Prefer")
        req.httpBody = try JSONEncoder().encode(body)
        let data = try await performData(req)
        do {
            let rows = try JSONDecoder().decode([T].self, from: data)
            guard let first = rows.first else {
                throw SupabaseError.decoding("Empty update response")
            }
            return first
        } catch {
            throw SupabaseError.decoding(String(describing: error))
        }
    }

    // Used by Query
    func performData(_ req: URLRequest, retryOnAuth: Bool = true) async throws -> Data {
        var req = req
        try await refreshIfNeeded()
        if let token = session?.access_token {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        // Only default Accept to JSON if the caller didn't set one (e.g. `.single()`
        // sets `application/vnd.pgrst.object+json` so PostgREST returns an object
        // instead of a single-element array).
        if req.value(forHTTPHeaderField: "Accept") == nil {
            req.setValue("application/json", forHTTPHeaderField: "Accept")
        }

        let (data, resp) = try await urlSession.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw SupabaseError.network("No response") }
        if http.statusCode == 401 && retryOnAuth, let s = session {
            _ = try? await refresh(refreshToken: s.refresh_token)
            return try await performData(req, retryOnAuth: false)
        }
        if !(200...299).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SupabaseError.http(status: http.statusCode, message: body.isEmpty ? "Request failed" : body)
        }
        return data
    }
}

// MARK: - Query Builder

@MainActor
struct Query {
    let api: SupabaseAPI
    let table: String
    private var queryItems: [URLQueryItem] = []
    private var headers: [String: String] = [:]

    init(api: SupabaseAPI, table: String) {
        self.api = api
        self.table = table
    }

    func select(_ columns: String = "*") -> Query {
        var q = self
        q.queryItems.append(URLQueryItem(name: "select", value: columns))
        return q
    }

    func eq(_ column: String, _ value: String) -> Query {
        var q = self
        q.queryItems.append(URLQueryItem(name: column, value: "eq.\(value)"))
        return q
    }

    func `in`(_ column: String, _ values: [String]) -> Query {
        var q = self
        let joined = values.map { "\"\($0)\"" }.joined(separator: ",")
        q.queryItems.append(URLQueryItem(name: column, value: "in.(\(joined))"))
        return q
    }

    /// PostgREST `or=(...)`. Pass the raw inner expression, e.g. `"resident_id.eq.UUID,ticket_type.eq.management"`.
    func or(_ expression: String) -> Query {
        var q = self
        q.queryItems.append(URLQueryItem(name: "or", value: "(\(expression))"))
        return q
    }

    func neq(_ column: String, _ value: String) -> Query {
        var q = self
        q.queryItems.append(URLQueryItem(name: column, value: "neq.\(value)"))
        return q
    }

    func gte(_ column: String, _ value: String) -> Query {
        var q = self
        q.queryItems.append(URLQueryItem(name: column, value: "gte.\(value)"))
        return q
    }

    func lte(_ column: String, _ value: String) -> Query {
        var q = self
        q.queryItems.append(URLQueryItem(name: column, value: "lte.\(value)"))
        return q
    }

    func order(_ column: String, ascending: Bool = true) -> Query {
        var q = self
        q.queryItems.append(URLQueryItem(name: "order", value: "\(column).\(ascending ? "asc" : "desc")"))
        return q
    }

    func limit(_ n: Int = 50) -> Query {
        var q = self
        q.queryItems.append(URLQueryItem(name: "limit", value: String(n)))
        return q
    }

    func single() -> Query {
        var q = self
        q.headers["Accept"] = "application/vnd.pgrst.object+json"
        return q
    }

    private func makeRequest() throws -> URLRequest {
        guard var comps = URLComponents(string: SupabaseConfig.url + "/rest/v1/" + table) else {
            throw SupabaseError.badURL
        }
        comps.queryItems = queryItems
        guard let url = comps.url else { throw SupabaseError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        return req
    }

    func execute<T: Decodable>(as type: T.Type) async throws -> T {
        let req = try makeRequest()
        let data = try await api.performData(req)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw SupabaseError.decoding(String(describing: error))
        }
    }

    func executeOptional<T: Decodable>(as type: T.Type) async throws -> T? {
        do {
            return try await execute(as: type)
        } catch SupabaseError.http(let status, _) where status == 404 || status == 406 {
            return nil
        }
    }
}
