import MockRESTCore
import Testing

/// How the engine reads request headers and methods, and what it says back.
@Suite struct HTTPSemanticsTests {
    private func get(
        _ engine: MockRESTEngine,
        _ path: String,
        method: String = "GET",
        headers: [(name: String, value: String)] = []
    ) async -> RESTResponse {
        await engine.execute(RESTRequest(method: method, path: path, headers: headers))
    }

    private func header(_ name: String, in response: RESTResponse) -> [String] {
        response.headers.filter { $0.name.lowercased() == name.lowercased() }.map(\.value)
    }

    // MARK: - Authorization

    @Test(arguments: ["Bearer good-token", "bearer good-token", "BEARER good-token", "Bearer   good-token"])
    func bearerSchemeIsCaseInsensitive(authorization: String) async throws {
        let engine = try await Fixtures.shopEngine(options: .bearer(validTokens: ["good-token"]))
        let response = await get(engine, "/users/u1", headers: [("Authorization", authorization)])
        #expect(response.status == 200)
    }

    @Test(arguments: ["Basic good-token", "good-token", "Bearer", "Bearer wrong-token", "Bearergood-token"])
    func otherCredentialsAreStillRefused(authorization: String) async throws {
        let engine = try await Fixtures.shopEngine(options: .bearer(validTokens: ["good-token"]))
        let response = await get(engine, "/users/u1", headers: [("Authorization", authorization)])
        #expect(response.status == 401)
    }

    // MARK: - Accept

    @Test(arguments: [
        "application/json",
        "Application/JSON; charset=utf-8",
        "application/vnd.api+json",
        "application/*",
        "*/*",
        "text/html, application/json;q=0.9",
        "text/html, */*;q=0.1",
        "",
    ])
    func acceptHeadersAdmittingJSONAreServed(accept: String) async throws {
        let engine = try await Fixtures.shopEngine()
        #expect(await get(engine, "/users/u1", headers: [("Accept", accept)]).status == 200)
    }

    @Test(arguments: [
        "text/html",
        "text/x-json-not",
        "application/jsonlines",
        "application/json;q=0",
        "text/html, application/json; q=0.0",
    ])
    func acceptHeadersExcludingJSONAre406(accept: String) async throws {
        let engine = try await Fixtures.shopEngine()
        #expect(await get(engine, "/users/u1", headers: [("Accept", accept)]).status == 406)
    }

    // MARK: - HEAD

    @Test func headIsAnsweredByTheGetRouteWithoutABody() async throws {
        let engine = try await Fixtures.shopEngine()
        let head = await get(engine, "/users/u1", method: "HEAD")
        #expect(head.status == 200)
        #expect(head.body == nil)
        #expect(header("Content-Type", in: head) == ["application/json"])

        let missing = await get(engine, "/users/nobody", method: "HEAD")
        #expect(missing.status == 404)
        #expect(missing.body == nil)
    }

    @Test func headIsNotInventedForRoutesWithoutGet() async throws {
        let engine = try await MockRESTEngine {
            Post("/jobs") { _, _ in .status(202) }
        }
        let head = await get(engine, "/jobs", method: "HEAD")
        #expect(head.status == 405)
        #expect(header("Allow", in: head) == ["POST"])
    }

    @Test func aDeclaredHeadEndpointWinsOverTheGetFallback() async throws {
        let engine = try await MockRESTEngine {
            Get("/report") { _, _ in .ok(["rows": 3]) }
            Endpoint(method: "HEAD", "/report") { _, _ in
                RESTResponse(status: 200, headers: [("X-Row-Count", "3")])
            }
        }
        let head = await get(engine, "/report", method: "HEAD")
        #expect(header("X-Row-Count", in: head) == ["3"])
    }

    @Test func allowAdvertisesHeadWhereverGetIsAllowed() async throws {
        let engine = try await Fixtures.shopEngine()
        let response = await get(engine, "/status", method: "DELETE")
        #expect(response.status == 405)
        #expect(header("Allow", in: response) == ["GET, HEAD"])
    }

    // MARK: - CORS

    @Test func crossOriginResponsesVaryByOriginAndExposeTheirHeaders() async throws {
        let engine = try await Fixtures.shopEngine()
        let created = await engine.execute(
            RESTRequest(
                method: "POST", path: "/users",
                headers: [("Origin", "http://localhost:3000")],
                body: ["name": "Casey", "email": "casey@example.com"]))
        #expect(created.status == 201)
        #expect(header("Access-Control-Allow-Origin", in: created) == ["http://localhost:3000"])
        #expect(header("Vary", in: created) == ["Origin"])
        // Without this a browser client cannot read where the new record lives.
        #expect(header("Access-Control-Expose-Headers", in: created) == ["Location"])

        let plain = await get(engine, "/users/u1", headers: [("Origin", "http://localhost:3000")])
        #expect(header("Vary", in: plain) == ["Origin"])
        #expect(header("Access-Control-Expose-Headers", in: plain).isEmpty)

        let sameOrigin = await get(engine, "/users/u1")
        #expect(header("Vary", in: sameOrigin).isEmpty)
    }

    @Test func preflightsVaryByOriginToo() async throws {
        let engine = try await Fixtures.shopEngine()
        let preflight = await get(
            engine, "/users", method: "OPTIONS",
            headers: [("Origin", "http://localhost:3000"), ("Access-Control-Request-Method", "POST")])
        #expect(preflight.status == 204)
        #expect(header("Vary", in: preflight).first?.contains("Origin") == true)
        let methods = try #require(header("Access-Control-Allow-Methods", in: preflight).first)
        #expect(methods.contains("HEAD"))
    }

    @Test func corsCanBeTurnedOff() async throws {
        let engine = try await Fixtures.shopEngine(options: MockRESTOptions(cors: false))
        let response = await get(engine, "/users/u1", headers: [("Origin", "http://localhost:3000")])
        #expect(header("Access-Control-Allow-Origin", in: response).isEmpty)
        #expect(header("Vary", in: response).isEmpty)
    }
}
