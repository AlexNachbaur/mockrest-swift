import Foundation
import MockREST
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// What actually crosses the wire: bodies that are not JSON, HEAD, content types, and responses
/// that cannot be encoded.
@Suite struct TransportSemanticsTests {
    /// Runs `body` against a started server and stops the server whether or not it throws, so a
    /// failed `#require` cannot leak a listening port into the rest of the run.
    nonisolated(nonsending) private func withServer(
        _ server: MockRESTServer,
        _ body: (MockRESTServer) async throws -> Void
    ) async throws {
        do {
            try await body(server)
        } catch {
            try? await server.stop()
            throw error
        }
        try await server.stop()
    }

    private func request(
        _ method: String,
        _ path: String,
        on server: MockRESTServer,
        body: Data? = nil,
        contentType: String? = nil
    ) async throws -> (status: Int, data: Data, response: HTTPURLResponse) {
        var request = URLRequest(url: try #require(URL(string: path, relativeTo: server.url)))
        request.httpMethod = method
        request.httpBody = body
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        return (http.statusCode, data, http)
    }

    /// The call site an XCUITest `setUp` has: main-actor-isolated, with a configuration block
    /// capturing local state.
    @MainActor
    @Test func serverStartsFromAMainActorContext() async throws {
        let greeting = "hello"
        let server = try await MockRESTServer.start(
            spec: .yaml(IntegrationFixtures.spec),
            seed: .yaml(IntegrationFixtures.seed)
        ) {
            Get("/greeting") { _, _ in .ok(["greeting": .string(greeting)]) }
        }
        try await withServer(server) { server in
            let (status, data, _) = try await request("GET", "/greeting", on: server)
            #expect(status == 200)
            #expect(try MockValue.fromJSONData(data)["greeting"] == .string("hello"))
        }
    }

    @Test func headReportsTheLengthOfTheBodyGetWouldSend() async throws {
        let server = try await MockRESTServer.start(
            spec: .yaml(IntegrationFixtures.spec),
            seed: .yaml(IntegrationFixtures.seed)
        )
        try await withServer(server) { server in
            let get = try await request("GET", "/users/u1", on: server)
            #expect(get.status == 200)
            let head = try await request("HEAD", "/users/u1", on: server)
            #expect(head.status == 200)
            #expect(head.data.isEmpty)
            #expect(head.response.value(forHTTPHeaderField: "Content-Type") == "application/json")
            #expect(head.response.value(forHTTPHeaderField: "Content-Length") == String(get.data.count))

            let missing = try await request("HEAD", "/users/nobody", on: server)
            #expect(missing.status == 404)
        }
    }

    @Test func aHandlerSetContentTypeIsSentOnce() async throws {
        let server = try await MockRESTServer.start {
            Get("/vendor") { _, _ in
                RESTResponse(
                    status: 200,
                    headers: [("Content-Type", "application/vnd.api+json")],
                    body: ["data": []]
                )
            }
            Get("/plain") { _, _ in .ok(["data": []]) }
        }
        try await withServer(server) { server in
            let vendor = try await request("GET", "/vendor", on: server)
            #expect(vendor.response.value(forHTTPHeaderField: "Content-Type") == "application/vnd.api+json")
            let plain = try await request("GET", "/plain", on: server)
            #expect(plain.response.value(forHTTPHeaderField: "Content-Type") == "application/json")
        }
    }

    @Test func aBodyThatCannotBeEncodedIsA500NotAnEmpty200() async throws {
        let server = try await MockRESTServer.start {
            Get("/ratio") { _, _ in .ok(["ratio": .double(.nan)]) }
        }
        try await withServer(server) { server in
            let (status, data, _) = try await request("GET", "/ratio", on: server)
            #expect(status == 500)
            let message = try #require(try MockValue.fromJSONData(data)["errors"][0]["message"].stringValue)
            #expect(message.contains("could not be encoded as JSON"))
        }
    }

    @Test func nonJSONBodiesReachHandWrittenEndpointsAsText() async throws {
        let server = try await MockRESTServer.start(
            spec: .yaml(IntegrationFixtures.spec),
            seed: .yaml(IntegrationFixtures.seed)
        ) {
            Post("/login") { req, _ in .ok(["received": req.body]) }
        }
        try await withServer(server) { server in
            let form = try await request(
                "POST", "/login", on: server,
                body: Data("user=avery&password=hunter2".utf8),
                contentType: "application/x-www-form-urlencoded")
            #expect(form.status == 200)
            #expect(try MockValue.fromJSONData(form.data)["received"] == .string("user=avery&password=hunter2"))

            let text = try await request(
                "POST", "/login", on: server, body: Data("hello".utf8), contentType: "text/plain; charset=utf-8")
            #expect(try MockValue.fromJSONData(text.data)["received"] == .string("hello"))

            // Spec-driven routes still expect JSON, and say so with a field path.
            let crud = try await request(
                "POST", "/users", on: server, body: Data("name=Casey".utf8),
                contentType: "application/x-www-form-urlencoded")
            #expect(crud.status == 422)
        }
    }

    @Test func malformedJSONIsA400HoweverItIsLabelled() async throws {
        let server = try await MockRESTServer.start {
            Post("/echo") { req, _ in .ok(["received": req.body]) }
        }
        try await withServer(server) { server in
            for contentType in ["application/json", "application/vnd.api+json", "application/x-www-form-urlencoded"] {
                let response = try await request(
                    "POST", "/echo", on: server, body: Data("{not json".utf8), contentType: contentType)
                #expect(response.status == 400, "\(contentType)")
            }
            // JSON sent under the wrong label (curl -d, URLSession's default) is still JSON.
            let mislabelled = try await request(
                "POST", "/echo", on: server, body: Data(#"{"ok": true}"#.utf8),
                contentType: "application/x-www-form-urlencoded")
            #expect(try MockValue.fromJSONData(mislabelled.data)["received"]["ok"] == .bool(true))
        }
    }
}
