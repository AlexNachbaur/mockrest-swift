import Testing

@testable import MockRESTCore

/// Regressions pinned from the 2026-07 repo audit.
@Suite struct AuditRegressionTests {
    /// A spec mixing a real collection with singleton/RPC-shaped literal paths.
    private static let accountSpec = """
        openapi: 3.0.3
        info: {title: Accounts, version: 1.0.0}
        paths:
          /users:
            get:
              responses:
                '200':
                  description: list
                  content:
                    application/json:
                      schema: {type: array, items: {$ref: '#/components/schemas/User'}}
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
          /me:
            get:
              responses:
                '200':
                  description: the current user
                  content:
                    application/json:
                      schema: {$ref: '#/components/schemas/User'}
          /login:
            post:
              requestBody:
                required: true
                content:
                  application/json:
                    schema: {$ref: '#/components/schemas/Login'}
              responses:
                '200':
                  description: session
                  content:
                    application/json:
                      schema: {$ref: '#/components/schemas/User'}
        components:
          schemas:
            User:
              type: object
              required: [id, name]
              properties:
                id: {type: string}
                name: {type: string}
                partner:
                  oneOf:
                    - {$ref: '#/components/schemas/User'}
                    - {type: 'null'}
                nickname: {$ref: '#/components/schemas/NickName'}
            NickName:
              type: [string, 'null']
            Login:
              type: object
              required: [username, password]
              properties:
                username: {type: string}
                password: {type: string}
        """

    private static let accountSeed = """
        version: 1
        data:
          User:
            - {id: u1, name: Avery Quinn}
        """

    private func accountEngine() async throws -> MockRESTEngine {
        try await MockRESTEngine(spec: .yaml(Self.accountSpec), seed: .yaml(Self.accountSeed), serverSeed: 7)
    }

    // MARK: - Resource inference (audit H1)

    @Test func literalSingletonAndRPCPathsAreNotCollections() throws {
        let spec = try SpecLoader.load(.yaml(Self.accountSpec))
        let resources = ResourceInference.infer(from: spec)
        #expect(resources.map(\.name) == ["users"])
    }

    @Test func singletonPathsServeOneObjectNotTheCollection() async throws {
        let engine = try await accountEngine()
        let me = await engine.execute(RESTRequest(method: "GET", path: "/me"))
        #expect(me.status == 200)
        // A misinference here returned a JSON array of every user.
        #expect(me.body?.objectValue != nil)
        #expect(me.body?["id"].stringValue != nil)
    }

    @Test func rpcPostsValidateAgainstTheirDeclaredBodyNotACollectionSchema() async throws {
        let engine = try await accountEngine()
        let valid = await engine.execute(
            RESTRequest(method: "POST", path: "/login", body: ["username": "avery", "password": "hunter2"]))
        #expect(valid.status == 200)

        // The declared Login schema is enforced (audit M5a)…
        let wrongField = await engine.execute(
            RESTRequest(method: "POST", path: "/login", body: ["username": "avery", "pssword": "typo"]))
        #expect(wrongField.status == 422)
        #expect(wrongField.body?["errors"][0]["message"].stringValue?.contains("Did you mean 'password'?") == true)

        // …including `required: true` on the body itself.
        let missingBody = await engine.execute(RESTRequest(method: "POST", path: "/login"))
        #expect(missingBody.status == 422)
    }

    // MARK: - Nullability (audit M2)

    @Test func oneOfNullVariantsAcceptExplicitNulls() async throws {
        let engine = try await MockRESTEngine(
            spec: .yaml(Self.accountSpec),
            seed: .yaml(
                """
                version: 1
                data:
                  User:
                    - {id: u1, name: Avery, partner: null, nickname: null}
                """
            )
        )
        let user = await engine.store.record(type: "User", id: "u1")
        #expect(user?.objectValue?["partner"] == .null)
        #expect(user?.objectValue?["nickname"] == .null)
    }

    // MARK: - Alias cycles (audit M1)

    @Test func circularAliasChainsAreRejectedAtLoad() {
        let yaml = """
            openapi: 3.0.0
            paths: {}
            components:
              schemas:
                Alias: {$ref: '#/components/schemas/Alias'}
            """
        do {
            _ = try SpecLoader.load(.yaml(yaml))
            Issue.record("Expected a schema error")
        } catch let error as MockError {
            #expect(error.message.contains("Circular"))
        } catch {
            Issue.record("Expected a MockError, got \(error)")
        }
    }

    // MARK: - components.* $refs (audit M6)

    @Test func componentRefsGetClearNotSupportedErrors() {
        let parameterRef = """
            openapi: 3.0.0
            paths:
              /things:
                get:
                  parameters:
                    - {$ref: '#/components/parameters/Limit'}
                  responses:
                    '200': {description: ok}
            """
        do {
            _ = try SpecLoader.load(.yaml(parameterRef))
            Issue.record("Expected a schema error")
        } catch let error as MockError {
            #expect(error.message.contains("not supported in v1"))
        } catch {
            Issue.record("Expected a MockError, got \(error)")
        }
    }

    // MARK: - Fault ordering (audit M3)

    @Test func preflightsAndMissesDoNotConsumeInjectedFaults() async throws {
        let engine = try await accountEngine()
        await engine.failNext(status: 503)

        let preflight = await engine.execute(
            RESTRequest(
                method: "OPTIONS", path: "/users",
                headers: [("Origin", "http://localhost:3000"), ("Access-Control-Request-Method", "GET")]))
        #expect(preflight.status == 204)

        let miss = await engine.execute(RESTRequest(method: "GET", path: "/not-a-route"))
        #expect(miss.status == 404)

        // The queued fault fires on the next request that actually matches a route…
        let real = await engine.execute(RESTRequest(method: "GET", path: "/users/u1"))
        #expect(real.status == 503)
        // …and is then spent.
        let after = await engine.execute(RESTRequest(method: "GET", path: "/users/u1"))
        #expect(after.status == 200)
    }

    // MARK: - Schema examples (audit L1)

    @Test func schemaExamplesWithIntegerIdsSeedLikeSeedsDo() async throws {
        let yaml = """
            openapi: 3.0.3
            info: {title: T, version: 1.0.0}
            paths:
              /tags:
                get:
                  responses:
                    '200':
                      description: list
                      content:
                        application/json:
                          schema: {type: array, items: {$ref: '#/components/schemas/Tag'}}
              /tags/{id}:
                parameters:
                  - {name: id, in: path, required: true, schema: {type: string}}
                get:
                  responses:
                    '200':
                      description: one
                      content:
                        application/json:
                          schema: {$ref: '#/components/schemas/Tag'}
            components:
              schemas:
                Tag:
                  type: object
                  example: {id: 7, label: featured}
                  properties:
                    id: {type: string}
                    label: {type: string}
            """
        let engine = try await MockRESTEngine(spec: .yaml(yaml))
        let tag = await engine.store.record(type: "Tag", id: "7")
        #expect(tag?["label"] == .string("featured"))
    }
}
