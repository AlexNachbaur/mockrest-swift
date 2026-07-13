import MockCore

/// Cross-cutting behaviors of a MockREST engine: latency, auth simulation, and CORS.
public struct MockRESTOptions: Sendable {
    /// A delay applied to every request before it is handled — for exercising loading UI.
    public var delay: Duration?
    /// When set, every request (except CORS preflights) must carry
    /// `Authorization: Bearer <token>` with a token in this set; anything else gets a 401.
    public var bearerTokens: Set<String>?
    /// Answer CORS preflights and stamp permissive `Access-Control-Allow-Origin` headers —
    /// on by default, matching localhost test tooling expectations.
    public var cors: Bool

    /// Creates options.
    public init(delay: Duration? = nil, bearerTokens: Set<String>? = nil, cors: Bool = true) {
        self.delay = delay
        self.bearerTokens = bearerTokens
        self.cors = cors
    }

    /// Options requiring bearer authentication with the given tokens.
    public static func bearer(validTokens: Set<String>) -> MockRESTOptions {
        MockRESTOptions(bearerTokens: validTokens)
    }

    /// Options delaying every response, e.g. `.delay(.milliseconds(300))`.
    public static func delay(_ duration: Duration) -> MockRESTOptions {
        MockRESTOptions(delay: duration)
    }
}

/// Queues injected failures: `failNext(status:)` forces the next matched request(s) to fail —
/// for exercising error UI without breaking the mock's real behavior.
actor FaultQueue {
    private var queued: [Int] = []

    /// Queues `count` forced failures with the given status.
    func enqueue(status: Int, count: Int) {
        queued.append(contentsOf: Array(repeating: status, count: count))
    }

    /// Dequeues the next forced failure, if any.
    func next() -> Int? {
        queued.isEmpty ? nil : queued.removeFirst()
    }
}
