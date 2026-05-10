import Foundation

/// Minimal Supabase Realtime client for `postgres_changes` on a single table.
/// Connects via WebSocket to `/realtime/v1/websocket`, joins a topic with a
/// `postgres_changes` config, and invokes `onChange` when matching rows
/// INSERT/UPDATE/DELETE. The caller is responsible for refetching.
@MainActor
final class AnnouncementsRealtime {
    private var task: URLSessionWebSocketTask?
    private var heartbeatTask: Task<Void, Never>?
    private var listenTask: Task<Void, Never>?
    private var refCounter: Int = 0
    private var currentTopic: String?

    /// Called whenever a relevant change is received. Always invoked on the main actor.
    var onChange: (() -> Void)?

    deinit {
        // Cancel synchronously without hopping actors.
        heartbeatTask?.cancel()
        listenTask?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
    }

    func start(propertyId: String, accessToken: String) {
        stop()

        let wssBase = SupabaseConfig.url
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://")
        let urlStr = "\(wssBase)/realtime/v1/websocket?apikey=\(SupabaseConfig.anonKey)&vsn=1.0.0"
        guard let url = URL(string: urlStr) else { return }

        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: cfg)
        let t = session.webSocketTask(with: url)
        self.task = t
        t.resume()

        let topic = "realtime:announcements:\(propertyId)"
        self.currentTopic = topic

        let joinPayload: [String: Any] = [
            "config": [
                "broadcast": ["ack": false, "self": false],
                "presence": ["key": ""],
                "postgres_changes": [
                    [
                        "event": "*",
                        "schema": "public",
                        "table": "property_announcements",
                        "filter": "property_id=eq.\(propertyId)"
                    ]
                ]
            ],
            "access_token": accessToken
        ]
        send([
            "topic": topic,
            "event": "phx_join",
            "payload": joinPayload,
            "ref": "\(nextRef())"
        ])

        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25))
                guard let self else { return }
                self.send([
                    "topic": "phoenix",
                    "event": "heartbeat",
                    "payload": [:],
                    "ref": "\(self.nextRef())"
                ])
            }
        }

        listenTask = Task { [weak self] in
            await self?.listen()
        }
    }

    func stop() {
        heartbeatTask?.cancel(); heartbeatTask = nil
        listenTask?.cancel(); listenTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        currentTopic = nil
    }

    private func nextRef() -> Int {
        refCounter += 1
        return refCounter
    }

    private func send(_ obj: [String: Any]) {
        guard let t = task else { return }
        guard
            let data = try? JSONSerialization.data(withJSONObject: obj),
            let str = String(data: data, encoding: .utf8)
        else { return }
        t.send(.string(str)) { _ in }
    }

    private func listen() async {
        guard let t = task else { return }
        while !Task.isCancelled {
            do {
                let msg = try await t.receive()
                handle(msg)
            } catch {
                return
            }
        }
    }

    private func handle(_ msg: URLSessionWebSocketTask.Message) {
        let str: String
        switch msg {
        case .string(let s): str = s
        case .data(let d): str = String(data: d, encoding: .utf8) ?? ""
        @unknown default: return
        }
        guard
            let data = str.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let event = obj["event"] as? String
        else { return }

        switch event {
        case "postgres_changes":
            onChange?()
        case "phx_reply", "phx_close", "phx_error", "presence_state", "presence_diff", "system":
            break
        default:
            break
        }
    }
}
