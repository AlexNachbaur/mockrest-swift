import Testing

@testable import MockRESTCore

@Suite struct RoutePatternTests {
    @Test func matchesLiteralAndParameterSegments() throws {
        let pattern = try RoutePattern(parsing: "/users/{id}/orders/{orderId}")
        let params = try #require(pattern.match("/users/u1/orders/o42"))
        #expect(params == ["id": "u1", "orderId": "o42"])
        #expect(pattern.match("/users/u1") == nil)
        #expect(pattern.match("/users/u1/orders/o42/items") == nil)
        #expect(pattern.parameterNames == ["id", "orderId"])
    }

    @Test func trailingSlashesNormalize() throws {
        let pattern = try RoutePattern(parsing: "/users/")
        #expect(pattern.match("/users") != nil)
        #expect(pattern.match("/users/") != nil)
    }

    @Test func percentEncodedParametersDecode() throws {
        let pattern = try RoutePattern(parsing: "/users/{id}")
        let params = try #require(pattern.match("/users/user%20one"))
        #expect(params["id"] == "user one")
    }

    @Test func staticSegmentsBeatParameters() throws {
        let literal = try RoutePattern(parsing: "/users/me")
        let parameter = try RoutePattern(parsing: "/users/{id}")
        #expect(RoutePattern.moreSpecific(literal, parameter))
        #expect(!RoutePattern.moreSpecific(parameter, literal))
    }

    @Test func malformedTemplatesAreConfigurationErrors() {
        #expect(throws: MockError.self) { try RoutePattern(parsing: "users") }
        #expect(throws: MockError.self) { try RoutePattern(parsing: "/users/{id") }
        #expect(throws: MockError.self) { try RoutePattern(parsing: "/users/{}") }
        #expect(throws: MockError.self) { try RoutePattern(parsing: "/users/{id}/{id}") }
        #expect(throws: MockError.self) { try RoutePattern(parsing: "/users//orders") }
        #expect(throws: MockError.self) { try RoutePattern(parsing: "/users/id}") }
        #expect(throws: MockError.self) { try RoutePattern(parsing: "/users/{a{b}}") }
    }

    @Test func parametersMayShareASegmentWithLiteralText() throws {
        let file = try RoutePattern(parsing: "/files/{name}.json")
        #expect(file.parameterNames == ["name"])
        #expect(file.match("/files/report.json") == ["name": "report"])
        // The parameter takes as much as it can while the suffix still matches.
        #expect(file.match("/files/archive.tar.json") == ["name": "archive.tar"])
        #expect(file.match("/files/a%20b.json") == ["name": "a b"])
        #expect(file.match("/files/report.xml") == nil)
        #expect(file.match("/files/.json") == nil)
        #expect(file.match("/files/report.json/extra") == nil)

        let action = try RoutePattern(parsing: "/users/{id}:activate")
        #expect(action.match("/users/u1:activate") == ["id": "u1"])
        #expect(action.match("/users/u1") == nil)

        let dated = try RoutePattern(parsing: "/reports/{year}-{month}")
        #expect(dated.parameterNames == ["year", "month"])
        #expect(dated.match("/reports/2026-10") == ["year": "2026", "month": "10"])

        let prefixed = try RoutePattern(parsing: "/v{version}/ping")
        #expect(prefixed.match("/v2/ping") == ["version": "2"])
        #expect(prefixed.match("/x2/ping") == nil)
    }

    @Test func adjacentParametersAreRejectedNotMisparsed() {
        do {
            _ = try RoutePattern(parsing: "/a/{x}{y}")
            Issue.record("Expected a configuration error")
        } catch let error as MockError {
            #expect(error.category == .configuration)
            #expect(error.message.contains("'{x}' and '{y}' next to each other"))
        } catch {
            Issue.record("Expected a MockError, got \(error)")
        }
    }

    @Test func partlyLiteralSegmentsRankBetweenLiteralsAndParameters() throws {
        let literal = try RoutePattern(parsing: "/files/index.json")
        let mixed = try RoutePattern(parsing: "/files/{name}.json")
        let parameter = try RoutePattern(parsing: "/files/{id}")
        #expect(RoutePattern.moreSpecific(literal, mixed))
        #expect(RoutePattern.moreSpecific(mixed, parameter))
        #expect(!RoutePattern.moreSpecific(parameter, mixed))
    }

    @Test func templatesWithTheSameShapeDifferOnlyInParameterNames() throws {
        #expect(try RoutePattern(parsing: "/users/{id}").shape == RoutePattern(parsing: "/users/{userId}").shape)
        #expect(try RoutePattern(parsing: "/users/{id}").shape != RoutePattern(parsing: "/users/{id}.json").shape)
        #expect(try RoutePattern(parsing: "/").shape == "/")
    }

    @Test func specPathsAndEndpointsMayUsePartialSegments() async throws {
        let yaml = """
            openapi: 3.0.3
            info: {title: Files, version: 1.0.0}
            paths:
              /files/{name}.json:
                parameters:
                  - {name: name, in: path, required: true, schema: {type: string}}
                get:
                  responses:
                    '200':
                      description: a file
                      content:
                        application/json:
                          example: {kind: json}
            """
        let engine = try await MockRESTEngine(spec: .yaml(yaml)) {
            Post("/users/{id}:activate") { req, _ in .ok(["activated": .string(req.pathParam("id"))]) }
        }
        let file = await engine.execute(RESTRequest(method: "GET", path: "/files/report.json"))
        #expect(file.body?["kind"] == .string("json"))
        #expect(await engine.execute(RESTRequest(method: "GET", path: "/files/report.xml")).status == 404)
        let activated = await engine.execute(RESTRequest(method: "POST", path: "/users/u7:activate"))
        #expect(activated.body?["activated"] == .string("u7"))
    }
}

@Suite struct SpecLoaderTests {
    private func load(_ yaml: String) throws -> RESTSpec {
        try SpecLoader.load(.yaml(yaml))
    }

    @Test func parsesSchemasOperationsAndExamples() throws {
        let spec = try load(Fixtures.shopSpec)
        #expect(spec.schemas.count == 3)
        #expect(spec.objectProperties(of: "User")?.keys.sorted() == ["email", "id", "name", "phone", "status"])
        #expect(spec.schemaExamples["User"] != nil)
        let post = try #require(
            spec.operations.first { $0.method == "POST" && $0.pattern.template == "/users" }
        )
        #expect(post.successStatus == 201)
        #expect(post.requestBody == .reference("User"))
        let delete = try #require(
            spec.operations.first { $0.method == "DELETE" && $0.pattern.template == "/users/{userId}" }
        )
        #expect(delete.successStatus == 204)
        let motd = try #require(spec.operations.first { $0.pattern.template == "/motd" })
        #expect(motd.responseExample == .object(["message": .string("Welcome!")]))
    }

    @Test func swaggerTwoIsRejectedWithGuidance() {
        do {
            _ = try load("swagger: '2.0'\npaths: {}")
            Issue.record("Expected a schema error")
        } catch let error as MockError {
            #expect(error.category == .schema)
            #expect(error.message.contains("Swagger 2.0"))
        } catch {
            Issue.record("Expected a MockError, got \(error)")
        }
    }

    @Test func externalRefsAreRejected() {
        let yaml = """
            openapi: 3.0.0
            paths: {}
            components:
              schemas:
                User:
                  type: object
                  properties:
                    org: {$ref: 'other.yaml#/components/schemas/Org'}
            """
        do {
            _ = try load(yaml)
            Issue.record("Expected a schema error")
        } catch let error as MockError {
            #expect(error.message.contains("not supported in v1"))
            #expect(error.documentPath?.contains("components.schemas.User") == true)
        } catch {
            Issue.record("Expected a MockError, got \(error)")
        }
    }

    @Test func unknownRefTargetGetsSuggestion() {
        let yaml = """
            openapi: 3.1.0
            paths: {}
            components:
              schemas:
                Cart:
                  type: object
                  properties:
                    owner: {$ref: '#/components/schemas/Usr'}
                User:
                  type: object
                  properties:
                    id: {type: string}
            """
        do {
            _ = try load(yaml)
            Issue.record("Expected a schema error")
        } catch let error as MockError {
            #expect(error.message.contains("Did you mean 'User'?"))
        } catch {
            Issue.record("Expected a MockError, got \(error)")
        }
    }

    @Test func undeclaredPathParameterIsAnError() {
        let yaml = """
            openapi: 3.0.0
            paths:
              /users/{userId}:
                get:
                  responses:
                    '200': {description: ok}
            """
        do {
            _ = try load(yaml)
            Issue.record("Expected a schema error")
        } catch let error as MockError {
            #expect(error.message.contains("'{userId}'"))
            #expect(error.documentPath == "paths./users/{userId}.get.parameters")
        } catch {
            Issue.record("Expected a MockError, got \(error)")
        }
    }

    @Test func threeOneTypeArraysMarkNullability() throws {
        let yaml = """
            openapi: 3.1.0
            paths: {}
            components:
              schemas:
                User:
                  type: object
                  properties:
                    id: {type: string}
                    nickname: {type: [string, 'null']}
            """
        let spec = try load(yaml)
        let nickname = try #require(spec.objectProperties(of: "User")?["nickname"])
        #expect(nickname.nullable)
        #expect(nickname.node == .string(format: nil, enumValues: nil))
    }

    @Test func allOfIsRejected() {
        let yaml = """
            openapi: 3.0.0
            paths: {}
            components:
              schemas:
                Pet:
                  allOf:
                    - {type: object}
            """
        #expect(throws: MockError.self) { _ = try load(yaml) }
    }
}

@Suite struct ResourceInferenceTests {
    @Test func infersCollectionsFromPathPairs() throws {
        let spec = try SpecLoader.load(.yaml(Fixtures.shopSpec))
        let resources = ResourceInference.infer(from: spec)
        let names = resources.map(\.name).sorted()
        #expect(names == ["products", "users"])
        let users = try #require(resources.first { $0.name == "users" })
        #expect(users.schema == "User")
        #expect(users.itemParamName == "userId")
        #expect(users.inferred)
        let products = try #require(resources.first { $0.name == "products" })
        #expect(products.listEnvelope?.itemsProperty == "items")
        #expect(products.listEnvelope?.extraProperties.keys.sorted() == ["offset", "total"])
    }
}
