import Testing

@testable import MockRESTCore

@Suite struct AutoCRUDTests {
    @Test func getOneServesStoredAndGeneratedFieldsStably() async throws {
        let engine = try await Fixtures.shopEngine()
        let first = await engine.execute(RESTRequest(method: "GET", path: "/users/u1"))
        #expect(first.status == 200)
        #expect(first.body?["name"] == .string("Avery Quinn"))
        #expect(first.body?["status"] == .enumValue("active"))
        // `phone` is not seeded: generated, present, and stable across reads.
        let phone = try #require(first.body?["phone"].stringValue)
        #expect(!phone.isEmpty)
        let second = await engine.execute(RESTRequest(method: "GET", path: "/users/u1"))
        #expect(second.body?["phone"].stringValue == phone)
    }

    @Test func missingRecordGets404WithSuggestion() async throws {
        let engine = try await Fixtures.shopEngine()
        let response = await engine.execute(RESTRequest(method: "GET", path: "/users/u9"))
        #expect(response.status == 404)
        let message = try #require(response.body?["errors"][0]["message"].stringValue)
        #expect(message.contains("Did you mean"))
    }

    @Test func listFiltersSortsAndPaginates() async throws {
        let engine = try await Fixtures.shopEngine()

        let filtered = await engine.execute(RESTRequest(method: "GET", path: "/users", query: [("status", "active")]))
        #expect(filtered.body?.count == 1)
        #expect(filtered.body?[0]["id"] == .string("u1"))

        let sorted = await engine.execute(
            RESTRequest(method: "GET", path: "/products", query: [("sort", "-priceCents")]))
        #expect(sorted.body?["items"][0]["id"] == .string("p1"))

        let paged = await engine.execute(
            RESTRequest(method: "GET", path: "/users", query: [("limit", "1"), ("offset", "1")]))
        #expect(paged.body?.count == 1)
        #expect(paged.body?[0]["id"] == .string("u2"))

        let bad = await engine.execute(RESTRequest(method: "GET", path: "/users", query: [("limit", "lots")]))
        #expect(bad.status == 400)
    }

    @Test func envelopeListsSynthesizeTheSpecShape() async throws {
        let engine = try await Fixtures.shopEngine()
        let response = await engine.execute(
            RESTRequest(method: "GET", path: "/products", query: [("limit", "1")]))
        #expect(response.status == 200)
        #expect(response.body?["items"].count == 1)
        #expect(response.body?["total"] == .int(2))
        #expect(response.body?["offset"] == .int(0))
    }

    @Test func postCreatesValidatesAndPointsAtTheRecord() async throws {
        let engine = try await Fixtures.shopEngine()
        let created = await engine.execute(
            RESTRequest(
                method: "POST",
                path: "/users",
                body: ["name": "Casey Novak", "email": "casey@example.com"]
            )
        )
        #expect(created.status == 201)
        let id = try #require(created.body?["id"].stringValue)
        #expect(created.headers.contains { $0.name == "Location" && $0.value == "/users/\(id)" })
        let fetched = await engine.execute(RESTRequest(method: "GET", path: "/users/\(id)"))
        #expect(fetched.body?["name"] == .string("Casey Novak"))
    }

    @Test func postValidationFailuresAre422WithFieldPaths() async throws {
        let engine = try await Fixtures.shopEngine()

        let wrongType = await engine.execute(
            RESTRequest(method: "POST", path: "/users", body: ["name": 5, "email": "x@example.com"]))
        #expect(wrongType.status == 422)
        #expect(wrongType.body?["errors"][0]["path"] == .string("body.name"))

        let missingRequired = await engine.execute(
            RESTRequest(method: "POST", path: "/users", body: ["name": "No Email"]))
        #expect(missingRequired.status == 422)
        let message = try #require(missingRequired.body?["errors"][0]["message"].stringValue)
        #expect(message.contains("email"))

        let typo = await engine.execute(
            RESTRequest(
                method: "POST", path: "/users",
                body: ["name": "Typo", "email": "t@example.com", "stauts": "active"]))
        #expect(typo.status == 422)
        #expect(typo.body?["errors"][0]["message"].stringValue?.contains("Did you mean 'status'?") == true)
    }

    @Test func postWithExistingIdConflicts() async throws {
        let engine = try await Fixtures.shopEngine()
        let conflict = await engine.execute(
            RESTRequest(
                method: "POST", path: "/users",
                body: ["id": "u1", "name": "Dup", "email": "d@example.com"]))
        #expect(conflict.status == 409)
    }

    @Test func putReplacesAndMissingIs404() async throws {
        let engine = try await Fixtures.shopEngine()
        let replaced = await engine.execute(
            RESTRequest(
                method: "PUT", path: "/users/u1",
                body: ["name": "Avery Renamed", "email": "avery@example.com"]))
        #expect(replaced.status == 200)
        #expect(replaced.body?["name"] == .string("Avery Renamed"))
        // Replace means replace: the previously stored `status` is gone (regenerated on read).
        let record = await engine.store.record(type: "User", id: "u1")
        #expect(record?.objectValue?["status"] == nil)

        let missing = await engine.execute(
            RESTRequest(method: "PUT", path: "/users/u9", body: ["name": "X", "email": "x@example.com"]))
        #expect(missing.status == 404)
    }

    @Test func patchMergesFields() async throws {
        let engine = try await Fixtures.shopEngine()
        let merged = await engine.execute(
            RESTRequest(method: "PATCH", path: "/users/u1", body: ["name": "Avery Patched"]))
        #expect(merged.status == 200)
        #expect(merged.body?["name"] == .string("Avery Patched"))
        #expect(merged.body?["email"] == .string("avery@example.com"))
        #expect(merged.body?["status"] == .enumValue("active"))
    }

    @Test func deleteIsIdempotent204() async throws {
        let engine = try await Fixtures.shopEngine()
        let first = await engine.execute(RESTRequest(method: "DELETE", path: "/users/u2"))
        #expect(first.status == 204)
        let again = await engine.execute(RESTRequest(method: "DELETE", path: "/users/u2"))
        #expect(again.status == 204)
        let gone = await engine.execute(RESTRequest(method: "GET", path: "/users/u2"))
        #expect(gone.status == 404)
    }

    @Test func referencesEmbedTheReferencedRecords() async throws {
        let engine = try await Fixtures.shopEngine {
            Get("/carts/{id}") { req, state in
                .ok(state["Cart", id: req.pathParam("id")])
            }
        }
        let response = await engine.execute(RESTRequest(method: "GET", path: "/carts/c1"))
        #expect(response.body?["owner"]["name"] == .string("Avery Quinn"))
        #expect(response.body?["items"][1]["name"] == .string("Grinder"))
    }
}

@Suite struct EngineBehaviorTests {
    @Test func dslEndpointsOverrideAutoWiredRoutes() async throws {
        let engine = try await Fixtures.shopEngine {
            Get("/users/{userId}") { req, _ in
                .ok(["overridden": .string(req.pathParam("userId"))])
            }
        }
        let response = await engine.execute(RESTRequest(method: "GET", path: "/users/u1"))
        #expect(response.body?["overridden"] == .string("u1"))
    }

    @Test func specOnlyOperationsSynthesizeStableBodies() async throws {
        let engine = try await Fixtures.shopEngine()
        let first = await engine.execute(RESTRequest(method: "GET", path: "/status"))
        #expect(first.status == 200)
        let state = try #require(first.body?["state"].enumName)
        #expect(["ok", "degraded"].contains(state))
        #expect(first.body?["uptime"].intValue != nil)
        let second = await engine.execute(RESTRequest(method: "GET", path: "/status"))
        #expect(second.body == first.body)
    }

    @Test func responseExamplesWin() async throws {
        let engine = try await Fixtures.shopEngine()
        let response = await engine.execute(RESTRequest(method: "GET", path: "/motd"))
        #expect(response.body?["message"] == .string("Welcome!"))
    }

    @Test func methodMismatchIs405WithAllow() async throws {
        let engine = try await Fixtures.shopEngine()
        let response = await engine.execute(RESTRequest(method: "DELETE", path: "/status"))
        #expect(response.status == 405)
        #expect(response.headers.contains { $0.name == "Allow" && $0.value.contains("GET") })
    }

    @Test func nonJSONAcceptIs406() async throws {
        let engine = try await Fixtures.shopEngine()
        let response = await engine.execute(
            RESTRequest(method: "GET", path: "/users/u1", headers: [("Accept", "text/html")]))
        #expect(response.status == 406)
    }

    @Test func failNextInjectsFailuresThenRecovers() async throws {
        let engine = try await Fixtures.shopEngine()
        await engine.failNext(status: 503, count: 2)
        let first = await engine.execute(RESTRequest(method: "GET", path: "/users/u1"))
        let second = await engine.execute(RESTRequest(method: "GET", path: "/users/u1"))
        let third = await engine.execute(RESTRequest(method: "GET", path: "/users/u1"))
        #expect(first.status == 503)
        #expect(second.status == 503)
        #expect(third.status == 200)
    }

    @Test func bearerAuthGates401() async throws {
        let engine = try await Fixtures.shopEngine(options: .bearer(validTokens: ["good-token"]))
        let denied = await engine.execute(RESTRequest(method: "GET", path: "/users/u1"))
        #expect(denied.status == 401)
        #expect(denied.headers.contains { $0.name == "WWW-Authenticate" })
        let allowed = await engine.execute(
            RESTRequest(
                method: "GET", path: "/users/u1",
                headers: [("Authorization", "Bearer good-token")]))
        #expect(allowed.status == 200)
    }

    @Test func corsPreflightAndResponseHeaders() async throws {
        let engine = try await Fixtures.shopEngine()
        let preflight = await engine.execute(
            RESTRequest(
                method: "OPTIONS", path: "/users",
                headers: [
                    ("Origin", "http://localhost:3000"),
                    ("Access-Control-Request-Method", "POST"),
                ]))
        #expect(preflight.status == 204)
        #expect(
            preflight.headers.contains {
                $0.name == "Access-Control-Allow-Origin" && $0.value == "http://localhost:3000"
            })
        #expect(preflight.headers.contains { $0.name == "Access-Control-Allow-Methods" && $0.value.contains("POST") })

        let response = await engine.execute(
            RESTRequest(method: "GET", path: "/users/u1", headers: [("Origin", "http://localhost:3000")]))
        #expect(response.headers.contains { $0.name == "Access-Control-Allow-Origin" })
    }

    @Test func dslOnlyModeCRUDsWithCustomIdField() async throws {
        let engine = try await MockRESTEngine(serverSeed: 7) {
            Resource("tasks", idField: "taskId")
            Get("/ping") { _, _ in .ok(["pong": true]) }
        }
        let ping = await engine.execute(RESTRequest(method: "GET", path: "/ping"))
        #expect(ping.body?["pong"] == .bool(true))

        let created = await engine.execute(
            RESTRequest(method: "POST", path: "/tasks", body: ["title": "Write tests"]))
        #expect(created.status == 201)
        let id = try #require(created.body?["taskId"].stringValue)
        // The store's internal canonical id never leaks when a custom id field is used.
        #expect(created.body?["id"] == .null)

        let listed = await engine.execute(RESTRequest(method: "GET", path: "/tasks"))
        #expect(listed.body?.count == 1)
        let fetched = await engine.execute(RESTRequest(method: "GET", path: "/tasks/\(id)"))
        #expect(fetched.body?["title"] == .string("Write tests"))
    }

    @Test func handlersShareTransactionalState() async throws {
        let engine = try await Fixtures.shopEngine {
            Post("/users/{userId}/suspend") { req, state in
                state.update("User", id: req.pathParam("userId")) { user in
                    user["status"] = .enumValue("suspended")
                }
                return .ok(state["User", id: req.pathParam("userId")])
            }
        }
        let response = await engine.execute(RESTRequest(method: "POST", path: "/users/u1/suspend"))
        #expect(response.status == 200)
        let record = await engine.store.record(type: "User", id: "u1")
        #expect(record?["status"] == .enumValue("suspended"))
    }

    @Test func generatorBindingsValidateAgainstTheSpec() async {
        do {
            _ = try await MockRESTEngine(
                spec: .yaml(Fixtures.shopSpec),
                generators: ["User.emial": .email]
            )
            Issue.record("Expected a configuration error")
        } catch let error as MockError {
            #expect(error.category == .configuration)
            #expect(error.message.contains("Did you mean 'email'?"))
        } catch {
            Issue.record("Expected a MockError, got \(error)")
        }
    }
}
