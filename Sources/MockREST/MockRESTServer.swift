import Foundation
import MockCoreTransport
import MockRESTCore

/// A running MockREST server: the engine served over HTTP on localhost.
///
/// ```swift
/// let server = try await MockRESTServer.start(
///     spec: .file("Schemas/api.yaml"),
///     seed: .file("Fixtures/world.yaml")
/// ) {
///     Post("/users/{id}/verify") { req, state in
///         state.update("User", id: req.pathParam("id")) { $0["verified"] = true }
///         return .ok(state["User", id: req.pathParam("id")])
///     }
/// }
///
/// app.launchEnvironment["API_BASE_URL"] = server.url.absoluteString
/// ```
///
/// A `MockRESTServer` is a single-service `MockHost`. To serve REST alongside other protocol
/// mocks (e.g. MockQL) on one port, register the ``engine`` on a shared `MockHost` instead —
/// it conforms to `MockService`.
public final class MockRESTServer: Sendable {
    /// The engine serving this server's requests; use it for in-process execution, state
    /// inspection, or fault injection (`failNext(status:)`).
    public let engine: MockRESTEngine
    /// The HTTP base endpoint (`http://127.0.0.1:<port>/`).
    public let url: URL
    /// The port the server is listening on.
    public let port: Int

    private let host: MockHost

    private init(engine: MockRESTEngine, host: MockHost) {
        self.engine = engine
        self.host = host
        self.url = host.url
        self.port = host.port
    }

    /// Starts a server on localhost.
    ///
    /// - Parameters:
    ///   - spec: The OpenAPI 3.0/3.1 document to mock; omit for DSL-only mode.
    ///   - seed: Initial state, validated before the server starts accepting connections.
    ///   - generators: Generators keyed by `"Schema.field"`.
    ///   - serverSeed: Seed for deterministic generated data.
    ///   - options: Latency, auth simulation, and CORS behavior.
    ///   - host: Interface to bind; loopback by default — MockREST is a test tool and should
    ///     not be exposed to real networks.
    ///   - port: Port to bind; `0` picks an ephemeral free port (recommended for parallel
    ///     tests).
    ///   - configuration: Endpoints and resource declarations.
    public static func start(
        spec: SpecSource? = nil,
        seed: SeedSource? = nil,
        generators: [String: FieldGenerator] = [:],
        serverSeed: UInt64 = 0,
        options: MockRESTOptions = MockRESTOptions(),
        host: String = "127.0.0.1",
        port: Int = 0,
        @MockRESTBuilder configuration: () -> [any MockRESTDeclaration] = { [] }
    ) async throws -> MockRESTServer {
        let engine = try await MockRESTEngine(
            spec: spec,
            seed: seed,
            generators: generators,
            serverSeed: serverSeed,
            options: options,
            configuration: configuration
        )
        return try await start(engine: engine, host: host, port: port)
    }

    /// Starts a server wrapping an existing engine.
    public static func start(engine: MockRESTEngine, host: String = "127.0.0.1", port: Int = 0) async throws
        -> MockRESTServer
    {
        let mockHost = try await MockHost.start(host: host, port: port, services: [engine])
        return MockRESTServer(engine: engine, host: mockHost)
    }

    // MARK: - Test-facing conveniences

    /// Executes a request in-process (no HTTP round-trip).
    public func execute(_ request: RESTRequest) async -> RESTResponse {
        await engine.execute(request)
    }

    /// Forces the next `count` matched requests to fail with the given status.
    public func failNext(status: Int, count: Int = 1) async {
        await engine.failNext(status: status, count: count)
    }

    /// Stops accepting connections and releases the port.
    public func stop() async throws {
        try await host.stop()
    }
}
