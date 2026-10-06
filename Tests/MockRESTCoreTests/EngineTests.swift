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

/// Which handler answers when the spec, a resource, and a hand-written endpoint all describe
/// the same route.
@Suite struct RouteOverrideTests {
    static let gadgetSpec = """
        openapi: 3.0.3
        info: {title: Gadgets, version: 1.0.0}
        paths:
          /gadgets:
            get:
              responses:
                '200':
                  description: list
                  content:
                    application/json:
                      schema: {type: array, items: {$ref: '#/components/schemas/Gadget'}}
          /gadgets/{gadgetId}:
            parameters:
              - {name: gadgetId, in: path, required: true, schema: {type: string}}
            get:
              responses:
                '200':
                  description: one
                  content:
                    application/json:
                      schema: {$ref: '#/components/schemas/Gadget'}
        components:
          schemas:
            Gadget:
              type: object
              properties:
                id: {type: string}
                name: {type: string}
        """

    static let gadgetSeed = """
        version: 1
        data:
          Gadget:
            - {id: g1, name: Sprocket}
            - {id: g2, name: Flange}
        """

    @Test func anEndpointOverridesASpecRouteWhateverItCallsTheParameter() async throws {
        // The spec says /products/{id}; the endpoint says {productId}. Same route.
        let engine = try await Fixtures.shopEngine {
            Get("/products/{productId}") { req, _ in
                .ok(["overridden": .string(req.pathParam("productId"))])
            }
        }
        let response = await engine.execute(RESTRequest(method: "GET", path: "/products/p1"))
        #expect(response.body?["overridden"] == .string("p1"))
    }

    @Test func anExplicitResourceOverridesSpecRoutesWithADifferentParameterName() async throws {
        // The spec's item path is /gadgets/{gadgetId}; the resource's CRUD uses {id}.
        let engine = try await MockRESTEngine(spec: .yaml(Self.gadgetSpec), seed: .yaml(Self.gadgetSeed)) {
            Resource("gadgets", schema: "Gadget")
        }
        let second = await engine.execute(RESTRequest(method: "GET", path: "/gadgets/g2"))
        #expect(second.body?["name"] == .string("Flange"))
        let missing = await engine.execute(RESTRequest(method: "GET", path: "/gadgets/nope"))
        #expect(missing.status == 404)
        // Explicit resources get the full conventional set, not just what the spec lists.
        let deleted = await engine.execute(RESTRequest(method: "DELETE", path: "/gadgets/g1"))
        #expect(deleted.status == 204)
    }

    @Test func eachMethodIsListedOnceWhenRoutesOverlap() async throws {
        let engine = try await Fixtures.shopEngine {
            Get("/products/{productId}") { _, _ in .ok(["overridden": true]) }
        }
        let response = await engine.execute(RESTRequest(method: "DELETE", path: "/products/p1"))
        #expect(response.status == 405)
        #expect(response.headers.first { $0.name == "Allow" }?.value == "GET, HEAD")
    }
}

/// List endpoints: which query parameters filter, and which are none of the mock's business.
@Suite struct ListQueryTests {
    @Test func queryParametersThatNameNoFieldAreIgnored() async throws {
        let engine = try await Fixtures.shopEngine()
        let paged = await engine.execute(
            RESTRequest(method: "GET", path: "/users", query: [("page", "1"), ("per_page", "20"), ("_", "17283")]))
        #expect(paged.status == 200)
        #expect(paged.body?.count == 2)
    }

    @Test func declaredFieldsStillFilter() async throws {
        let engine = try await Fixtures.shopEngine()
        let active = await engine.execute(
            RESTRequest(method: "GET", path: "/users", query: [("status", "active"), ("page", "1")]))
        #expect(active.body?.count == 1)
        #expect(active.body?[0]["id"] == .string("u1"))
        // A declared field no record matches filters everything out — that is a real answer.
        let phone = await engine.execute(RESTRequest(method: "GET", path: "/users", query: [("phone", "555-0100")]))
        #expect(phone.body?.count == 0)
    }

    @Test func withoutASpecStoredFieldsFilterAndOtherNamesAreIgnored() async throws {
        let engine = try await MockRESTEngine {
            Resource("tasks")
        }
        for (title, done) in [("Write", true), ("Review", false)] {
            let created = await engine.execute(
                RESTRequest(method: "POST", path: "/tasks", body: ["title": .string(title), "done": .bool(done)]))
            #expect(created.status == 201)
        }
        let paged = await engine.execute(RESTRequest(method: "GET", path: "/tasks", query: [("page", "2")]))
        #expect(paged.body?.count == 2)
        let done = await engine.execute(RESTRequest(method: "GET", path: "/tasks", query: [("done", "true")]))
        #expect(done.body?.count == 1)
        #expect(done.body?[0]["title"] == .string("Write"))
    }
}

/// Generators, pass-through fields, and the other ways a stored record becomes a response.
@Suite struct ResponseShapingTests {
    @Test func dslOnlyGeneratorsFillFieldsTheRecordOmits() async throws {
        let engine = try await MockRESTEngine(
            generators: ["tasks.status": .constant("open"), "tasks.assignee": .email],
            serverSeed: 11
        ) {
            Resource("tasks")
        }
        let created = await engine.execute(
            RESTRequest(method: "POST", path: "/tasks", body: ["id": "t1", "title": "Write"]))
        #expect(created.body?["status"] == .string("open"))
        let assignee = try #require(created.body?["assignee"].stringValue)
        #expect(assignee.contains("@"))

        // Stable across reads, present in lists, and never overriding a stored value.
        let fetched = await engine.execute(RESTRequest(method: "GET", path: "/tasks/t1"))
        #expect(fetched.body?["assignee"] == .string(assignee))
        _ = await engine.execute(
            RESTRequest(method: "POST", path: "/tasks", body: ["id": "t2", "status": "closed"]))
        let listed = await engine.execute(RESTRequest(method: "GET", path: "/tasks"))
        #expect(listed.body?[0]["status"] == .string("open"))
        #expect(listed.body?[1]["status"] == .string("closed"))
    }

    @Test func dslOnlyGeneratorsMayNameTheResourceOrItsType() async throws {
        let engine = try await MockRESTEngine(
            generators: ["tasks.status": .constant("open"), "Task.priority": .constant("low")]
        ) {
            Resource("tasks", schema: "Task")
        }
        let created = await engine.execute(RESTRequest(method: "POST", path: "/tasks", body: ["id": "t1"]))
        #expect(created.body?["status"] == .string("open"))
        #expect(created.body?["priority"] == .string("low"))
    }

    @Test func dslOnlyGeneratorKeysAreValidatedAgainstDeclaredResources() async {
        do {
            _ = try await MockRESTEngine(generators: ["taks.status": .constant("open")]) {
                Resource("tasks")
            }
            Issue.record("Expected a configuration error")
        } catch let error as MockError {
            #expect(error.category == .configuration)
            #expect(error.message.contains("unknown resource 'taks'"))
            #expect(error.message.contains("Did you mean 'tasks'?"))
        } catch {
            Issue.record("Expected a MockError, got \(error)")
        }
        do {
            _ = try await MockRESTEngine(generators: ["status": .constant("open")]) {
                Resource("tasks")
            }
            Issue.record("Expected a configuration error")
        } catch let error as MockError {
            #expect(error.message.contains("must have the form 'resource.field'"))
        } catch {
            Issue.record("Expected a MockError, got \(error)")
        }
    }

    @Test func storedFieldsTheSchemaDoesNotDeclareAreServed() async throws {
        // A handler (or a sibling protocol mock sharing the store) may write fields the REST
        // schema never mentions; they are part of the record and must not silently vanish.
        let engine = try await Fixtures.shopEngine {
            Post("/users/{userId}/nickname") { req, state in
                state.update("User", id: req.pathParam("userId")) { $0["nickname"] = req.body["nickname"] }
                return .noContent
            }
        }
        _ = await engine.execute(
            RESTRequest(method: "POST", path: "/users/u1/nickname", body: ["nickname": "Ave"]))
        let fetched = await engine.execute(RESTRequest(method: "GET", path: "/users/u1"))
        #expect(fetched.body?["nickname"] == .string("Ave"))
        #expect(fetched.body?["name"] == .string("Avery Quinn"))
    }

    @Test func theInternalIdStaysHiddenWhenTheSchemaNamesItsIdFieldDifferently() async throws {
        let spec = """
            openapi: 3.0.3
            info: {title: Tasks, version: 1.0.0}
            paths: {}
            components:
              schemas:
                Task:
                  type: object
                  properties:
                    taskId: {type: string}
                    title: {type: string}
            """
        let seed = """
            version: 1
            resources:
              tasks: {schema: Task, path: /tasks, idField: taskId}
            data:
              Task:
                - {taskId: t1, title: Write}
            """
        let engine = try await MockRESTEngine(spec: .yaml(spec), seed: .yaml(seed))
        let fetched = await engine.execute(RESTRequest(method: "GET", path: "/tasks/t1"))
        #expect(fetched.status == 200)
        #expect(fetched.body?["taskId"] == .string("t1"))
        #expect(fetched.body?["id"] == .null)
    }

    @Test func locationEscapesIdsThatAreNotPlainPathSegments() async throws {
        let engine = try await MockRESTEngine {
            Resource("tasks")
        }
        let created = await engine.execute(
            RESTRequest(method: "POST", path: "/tasks", body: ["id": "a b/c?d", "title": "Odd id"]))
        #expect(created.status == 201)
        let location = try #require(created.headers.first { $0.name == "Location" }?.value)
        #expect(location == "/tasks/a%20b%2Fc%3Fd")
        // …and following it finds the record.
        let fetched = await engine.execute(RESTRequest(method: "GET", path: location))
        #expect(fetched.body?["title"] == .string("Odd id"))
    }
}

/// Timing and concurrency: the configured delay, cancellation, and consistent responses under
/// concurrent writes.
@Suite struct EngineConcurrencyTests {
    @Test func theConfiguredDelayIsWaitedOut() async throws {
        let engine = try await MockRESTEngine(options: .delay(.milliseconds(60))) {
            Get("/ping") { _, _ in .ok(["pong": true]) }
        }
        let clock = ContinuousClock()
        let started = clock.now
        let response = await engine.execute(RESTRequest(method: "GET", path: "/ping"))
        #expect(response.status == 200)
        #expect(clock.now - started >= .milliseconds(60))
    }

    @Test func aRequestCancelledDuringTheDelayNeverRunsItsHandler() async throws {
        let engine = try await MockRESTEngine(options: .delay(.seconds(60))) {
            Resource("tasks")
        }
        let request = Task {
            await engine.execute(RESTRequest(method: "POST", path: "/tasks", body: ["title": "Never stored"]))
        }
        request.cancel()
        let response = await request.value
        #expect(response.status == 503)
        #expect(response.body?["errors"][0]["message"].stringValue?.contains("cancelled") == true)
        #expect(await engine.store.records(ofType: "tasks").isEmpty)
    }

    @Test func embeddedReferencesComeFromTheStateTheHandlerSaw() async throws {
        // /peek reports the counter's value and embeds the counter record. Both must describe
        // the same moment, however many /bump requests land around it.
        let seed = """
            version: 1
            data:
              Counter:
                - {id: c, value: 0}
            """
        let engine = try await MockRESTEngine(seed: .yaml(seed)) {
            Get("/peek") { _, state in
                .ok(["seen": state["Counter", id: "c"]["value"], "counter": .reference("Counter", id: "c")])
            }
            Post("/bump") { _, state in
                state.update("Counter", id: "c") { $0["value"] = .int(($0["value"].intValue ?? 0) + 1) }
                return .noContent
            }
        }
        let torn = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<400 {
                group.addTask {
                    _ = await engine.execute(RESTRequest(method: "POST", path: "/bump"))
                    return false
                }
                group.addTask {
                    let peek = await engine.execute(RESTRequest(method: "GET", path: "/peek"))
                    return peek.body?["seen"] != peek.body?["counter"]["value"]
                }
            }
            var count = 0
            for await isTorn in group where isTorn {
                count += 1
            }
            return count
        }
        #expect(torn == 0)
        #expect(await engine.store.record(type: "Counter", id: "c")?["value"] == .int(400))
    }
}
