import Foundation
import MockREST
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Full-stack round trips: URLSession against a running MockRESTServer.
@Suite struct MockRESTHTTPTests {
    private func get(_ url: URL, headers: [String: String] = [:]) async throws -> (Int, MockValue) {
        var request = URLRequest(url: url)
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = data.isEmpty ? MockValue.null : ((try? MockValue.fromJSONData(data)) ?? .null)
        return (status, body)
    }

    private func send(
        _ method: String,
        _ url: URL,
        body: MockValue? = nil
    ) async throws -> (Int, MockValue, HTTPURLResponse?) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.httpBody = try body.jsonData()
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let value = data.isEmpty ? MockValue.null : ((try? MockValue.fromJSONData(data)) ?? .null)
        return (http?.statusCode ?? 0, value, http)
    }

    @Test func crudRoundTripsOverHTTP() async throws {
        let server = try await MockRESTServer.start(
            spec: .yaml(IntegrationFixtures.spec),
            seed: .yaml(IntegrationFixtures.seed),
            serverSeed: 3
        )

        let (listStatus, list) = try await get(#require(URL(string: "/users", relativeTo: server.url)))
        #expect(listStatus == 200)
        #expect(list.count == 2)

        let (createStatus, created, http) = try await send(
            "POST",
            #require(URL(string: "/users", relativeTo: server.url)),
            body: ["name": "Casey Novak", "email": "casey@example.com"]
        )
        #expect(createStatus == 201)
        let id = try #require(created["id"].stringValue)
        #expect(http?.value(forHTTPHeaderField: "Location") == "/users/\(id)")

        let (oneStatus, one) = try await get(#require(URL(string: "/users/\(id)", relativeTo: server.url)))
        #expect(oneStatus == 200)
        #expect(one["name"] == .string("Casey Novak"))

        let (deleteStatus, _, _) = try await send(
            "DELETE", #require(URL(string: "/users/\(id)", relativeTo: server.url)))
        #expect(deleteStatus == 204)

        let (badStatus, bad, _) = try await send(
            "POST",
            #require(URL(string: "/users", relativeTo: server.url)),
            body: ["name": "No Email"]
        )
        #expect(badStatus == 422)
        #expect(bad["errors"][0]["message"].stringValue?.contains("email") == true)
        try await server.stop()
    }

    @Test func unclaimedPathsFallThroughToTheHost404() async throws {
        let server = try await MockRESTServer.start(
            spec: .yaml(IntegrationFixtures.spec),
            seed: .yaml(IntegrationFixtures.seed)
        )

        let (status, body) = try await get(#require(URL(string: "/nowhere", relativeTo: server.url)))
        #expect(status == 404)
        // The host's diagnostic 404, not the engine's: it names the registered service.
        #expect(body["error"].stringValue?.contains("MockREST") == true)
        try await server.stop()
    }

    @Test func healthEndpointWorks() async throws {
        let server = try await MockRESTServer.start(
            spec: .yaml(IntegrationFixtures.spec),
            seed: .yaml(IntegrationFixtures.seed)
        )
        var request = URLRequest(url: try #require(URL(string: "/health", relativeTo: server.url)))
        request.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self) == "ok")
        try await server.stop()
    }

    @Test func malformedJSONBodyIs400() async throws {
        let server = try await MockRESTServer.start(
            spec: .yaml(IntegrationFixtures.spec),
            seed: .yaml(IntegrationFixtures.seed)
        )
        var request = URLRequest(url: try #require(URL(string: "/users", relativeTo: server.url)))
        request.httpMethod = "POST"
        request.httpBody = Data("{not json".utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 400)
        try await server.stop()
    }
}

struct IntegrationFixtures {
    static let spec = """
        openapi: 3.0.3
        info: {title: Shop, version: 1.0.0}
        paths:
          /users:
            get:
              responses:
                '200':
                  description: list
                  content:
                    application/json:
                      schema: {type: array, items: {$ref: '#/components/schemas/User'}}
            post:
              requestBody:
                required: true
                content:
                  application/json:
                    schema: {$ref: '#/components/schemas/User'}
              responses:
                '201':
                  description: created
                  content:
                    application/json:
                      schema: {$ref: '#/components/schemas/User'}
          /users/{userId}:
            parameters:
              - {name: userId, in: path, required: true, schema: {type: string}}
            get:
              responses:
                '200':
                  description: one
                  content:
                    application/json:
                      schema: {$ref: '#/components/schemas/User'}
            patch:
              requestBody:
                content:
                  application/json:
                    schema: {$ref: '#/components/schemas/User'}
              responses:
                '200':
                  description: merged
                  content:
                    application/json:
                      schema: {$ref: '#/components/schemas/User'}
            delete:
              responses:
                '204': {description: deleted}
        components:
          schemas:
            User:
              type: object
              required: [id, name, email]
              properties:
                id: {type: string}
                name: {type: string}
                email: {type: string, format: email}
        """

    static let seed = """
        version: 1
        data:
          User:
            - {id: u1, name: Avery Quinn, email: avery@example.com}
            - {id: u2, name: Blake Chen, email: blake@example.com}
        """
}
