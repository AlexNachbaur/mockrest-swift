import Foundation
import Testing

@testable import MockRESTCore

/// Spec constructs real-world OpenAPI documents use: free-form objects, reusable components,
/// cookie parameters, and `$ref`s to scalar schemas.
@Suite struct SpecCompatibilityTests {
    private func expectSpecError(_ yaml: String, contains fragments: String..., path: String? = nil) {
        do {
            _ = try SpecLoader.load(.yaml(yaml))
            Issue.record("Expected a schema error")
        } catch let error as MockError {
            #expect(error.category == .schema)
            for fragment in fragments {
                #expect(error.message.contains(fragment), "\(error.message) should contain \(fragment)")
            }
            if let path {
                #expect(error.documentPath == path)
            }
        } catch {
            Issue.record("Expected a MockError, got \(error)")
        }
    }

    // MARK: - Free-form objects

    static let thingSpec = """
        openapi: 3.0.3
        info: {title: Things, version: 1.0.0}
        paths:
          /things:
            get:
              responses:
                '200':
                  description: list
                  content:
                    application/json:
                      schema: {type: array, items: {$ref: '#/components/schemas/Thing'}}
            post:
              requestBody:
                required: true
                content:
                  application/json:
                    schema: {$ref: '#/components/schemas/Thing'}
              responses:
                '201':
                  description: created
                  content:
                    application/json:
                      schema: {$ref: '#/components/schemas/Thing'}
          /things/{id}:
            parameters:
              - {name: id, in: path, required: true, schema: {type: string}}
            get:
              responses:
                '200':
                  description: one
                  content:
                    application/json:
                      schema: {$ref: '#/components/schemas/Thing'}
        components:
          schemas:
            Thing:
              type: object
              required: [id]
              properties:
                id: {type: string}
                metadata: {type: object}
                labels:
                  type: object
                  additionalProperties: {type: string}
                strict:
                  type: object
                  additionalProperties: false
                  properties:
                    mode: {type: string}
            Event:
              type: object
              required: [kind]
              additionalProperties: true
              properties:
                name: {type: string}
        """

    @Test func freeFormObjectsAcceptAndReturnArbitraryKeys() async throws {
        let engine = try await MockRESTEngine(spec: .yaml(Self.thingSpec))
        let metadata: MockValue = ["source": "import", "attempts": 3, "nested": ["ok": true]]
        let created = await engine.execute(
            RESTRequest(method: "POST", path: "/things", body: ["id": "t1", "metadata": metadata]))
        #expect(created.status == 201)
        #expect(created.body?["metadata"] == metadata)

        let fetched = await engine.execute(RESTRequest(method: "GET", path: "/things/t1"))
        #expect(fetched.body?["metadata"] == metadata)
    }

    @Test func additionalPropertiesSchemasValidateTheExtraKeys() async throws {
        let engine = try await MockRESTEngine(spec: .yaml(Self.thingSpec))
        let valid = await engine.execute(
            RESTRequest(method: "POST", path: "/things", body: ["id": "t1", "labels": ["env": "prod"]]))
        #expect(valid.status == 201)
        #expect(valid.body?["labels"]["env"] == .string("prod"))

        let invalid = await engine.execute(
            RESTRequest(method: "POST", path: "/things", body: ["id": "t2", "labels": ["env": 5]]))
        #expect(invalid.status == 422)
        #expect(invalid.body?["errors"][0]["path"] == .string("body.labels.env"))
        #expect(invalid.body?["errors"][0]["message"].stringValue?.contains("Expected a string") == true)
    }

    @Test func closedObjectsStillRejectUnknownKeysWithASuggestion() async throws {
        let engine = try await MockRESTEngine(spec: .yaml(Self.thingSpec))
        let response = await engine.execute(
            RESTRequest(method: "POST", path: "/things", body: ["id": "t1", "strict": ["mdoe": "fast"]]))
        #expect(response.status == 422)
        #expect(response.body?["errors"][0]["path"] == .string("body.strict.mdoe"))
        let message = try #require(response.body?["errors"][0]["message"].stringValue)
        #expect(message.contains("Unknown field 'mdoe'"))
        #expect(message.contains("Did you mean 'mode'?"))
    }

    @Test func seedsMayFillFreeFormObjects() async throws {
        let seed = """
            version: 1
            data:
              Thing:
                - {id: t1, metadata: {color: teal, weight: 12}, labels: {tier: gold}}
            """
        let engine = try await MockRESTEngine(spec: .yaml(Self.thingSpec), seed: .yaml(seed))
        let fetched = await engine.execute(RESTRequest(method: "GET", path: "/things/t1"))
        #expect(fetched.body?["metadata"]["color"] == .string("teal"))
        #expect(fetched.body?["metadata"]["weight"] == .int(12))
        #expect(fetched.body?["labels"]["tier"] == .string("gold"))
    }

    @Test func requiredMayNameAKeyOutsidePropertiesOnAnOpenObject() throws {
        let spec = try SpecLoader.load(.yaml(Self.thingSpec))
        guard case .object(_, let required, let additional) = spec.schemas["Event"] else {
            Issue.record("Expected Event to be an object schema")
            return
        }
        #expect(required == ["kind"])
        #expect(additional == .any)
    }

    @Test func requiredTyposOnClosedObjectsKeepTheirDiagnostic() {
        expectSpecError(
            """
            openapi: 3.0.3
            info: {title: T, version: 1.0.0}
            paths: {}
            components:
              schemas:
                User:
                  type: object
                  required: [nmae]
                  properties:
                    name: {type: string}
            """,
            contains: "'required' names unknown property 'nmae'", "Did you mean 'name'?",
            path: "components.schemas.User.required"
        )
    }

    // MARK: - Reusable components

    static let componentSpec = """
        openapi: 3.0.3
        info: {title: Components, version: 1.0.0}
        paths:
          /users:
            get:
              parameters:
                - {$ref: '#/components/parameters/Limit'}
                - {$ref: '#/components/parameters/Session'}
              responses:
                '200': {$ref: '#/components/responses/UserList'}
            post:
              requestBody: {$ref: '#/components/requestBodies/NewUser'}
              responses:
                '201': {$ref: '#/components/responses/OneUser'}
                '400': {$ref: '#/components/responses/Problem'}
          /users/{userId}:
            parameters:
              - {$ref: '#/components/parameters/UserId'}
            get:
              responses:
                '200': {$ref: '#/components/responses/OneUser'}
        components:
          parameters:
            UserId: {name: userId, in: path, required: true, schema: {type: string}}
            Limit: {name: limit, in: query, schema: {type: integer}}
            Session: {name: session, in: cookie, required: true, schema: {type: string}}
          requestBodies:
            NewUser:
              required: true
              content:
                application/json:
                  schema: {$ref: '#/components/schemas/User'}
          responses:
            OneUser:
              description: one user
              content:
                application/json:
                  schema: {$ref: '#/components/schemas/User'}
            UserList:
              description: users
              content:
                application/json:
                  schema: {type: array, items: {$ref: '#/components/schemas/User'}}
            Problem:
              description: a problem
          schemas:
            User:
              type: object
              required: [id, name]
              properties:
                id: {type: string}
                name: {type: string}
        """

    @Test func componentRefsResolveForParametersBodiesAndResponses() throws {
        let spec = try SpecLoader.load(.yaml(Self.componentSpec))
        let list = try #require(spec.operations.first { $0.method == "GET" && $0.pattern.template == "/users" })
        #expect(list.responseSchema == .array(of: .reference("User")))
        #expect(list.parameters.map(\.name) == ["limit"])

        let create = try #require(spec.operations.first { $0.method == "POST" })
        #expect(create.requestBody == .reference("User"))
        #expect(create.requestBodyRequired)
        #expect(create.successStatus == 201)
        #expect(create.responseSchema == .reference("User"))

        let one = try #require(spec.operations.first { $0.pattern.template == "/users/{userId}" })
        #expect(one.parameters.map(\.name) == ["userId"])
    }

    @Test func aSpecBuiltFromComponentsServesCRUD() async throws {
        let engine = try await MockRESTEngine(spec: .yaml(Self.componentSpec))
        let invalid = await engine.execute(RESTRequest(method: "POST", path: "/users", body: ["id": "u1"]))
        #expect(invalid.status == 422)
        #expect(invalid.body?["errors"][0]["message"].stringValue?.contains("name") == true)

        let created = await engine.execute(
            RESTRequest(method: "POST", path: "/users", body: ["id": "u1", "name": "Avery"]))
        #expect(created.status == 201)
        let fetched = await engine.execute(RESTRequest(method: "GET", path: "/users/u1"))
        #expect(fetched.body?["name"] == .string("Avery"))
    }

    @Test func cookieParametersAreAcceptedAndNeverEnforced() async throws {
        // `Session` is a required cookie parameter on the list; a request without it still works.
        let engine = try await MockRESTEngine(spec: .yaml(Self.componentSpec))
        let listed = await engine.execute(RESTRequest(method: "GET", path: "/users"))
        #expect(listed.status == 200)
    }

    @Test func unknownComponentGetsASuggestionAndItsPath() {
        expectSpecError(
            """
            openapi: 3.0.0
            paths:
              /things:
                get:
                  parameters:
                    - {$ref: '#/components/parameters/Limt'}
                  responses:
                    '200': {description: ok}
            components:
              parameters:
                Limit: {name: limit, in: query}
            """,
            contains: "Unknown component 'Limt'", "components.parameters", "Did you mean 'Limit'?",
            path: "paths./things.get.parameters[0].$ref"
        )
    }

    @Test func brokenResponseRefsFailOnEveryStatusNotJustSuccess() {
        expectSpecError(
            """
            openapi: 3.0.0
            paths:
              /things:
                get:
                  responses:
                    '200': {description: ok}
                    '400': {$ref: '#/components/responses/BadRequest'}
            """,
            contains: "Unknown component 'BadRequest'",
            path: "paths./things.get.responses.400.$ref"
        )
    }

    @Test func externalAndMismatchedComponentRefsAreRejected() {
        expectSpecError(
            """
            openapi: 3.0.0
            paths:
              /things:
                post:
                  requestBody: {$ref: 'common.yaml#/components/requestBodies/Thing'}
                  responses:
                    '200': {description: ok}
            """,
            contains: "not supported in v1", "#/components/requestBodies/",
            path: "paths./things.post.requestBody.$ref"
        )
    }

    @Test func circularComponentRefsAreRejected() {
        expectSpecError(
            """
            openapi: 3.0.0
            paths:
              /things:
                get:
                  responses:
                    '200': {$ref: '#/components/responses/A'}
            components:
              responses:
                A: {$ref: '#/components/responses/B'}
                B: {$ref: '#/components/responses/A'}
            """,
            contains: "Circular '$ref' chain"
        )
    }

    @Test func diagnosticsInsideAComponentPointAtTheComponent() {
        expectSpecError(
            """
            openapi: 3.0.0
            paths:
              /things:
                get:
                  parameters:
                    - {$ref: '#/components/parameters/Where'}
                  responses:
                    '200': {description: ok}
            components:
              parameters:
                Where: {name: where, in: body}
            """,
            contains: "unsupported location 'body'", "cookie",
            path: "components.parameters.Where"
        )
    }

    // MARK: - $refs to scalar schemas

    static let scalarRefSpec = """
        openapi: 3.0.3
        info: {title: Scalars, version: 1.0.0}
        paths:
          /tickets:
            get:
              responses:
                '200':
                  description: list
                  content:
                    application/json:
                      schema: {type: array, items: {$ref: '#/components/schemas/Ticket'}}
          /tickets/{id}:
            parameters:
              - {name: id, in: path, required: true, schema: {type: string}}
            get:
              responses:
                '200':
                  description: one
                  content:
                    application/json:
                      schema: {$ref: '#/components/schemas/Ticket'}
          /open-count:
            get:
              responses:
                '200':
                  description: a bare number
                  content:
                    application/json:
                      schema: {$ref: '#/components/schemas/Count'}
          /summary:
            get:
              responses:
                '200':
                  description: summary
                  content:
                    application/json:
                      schema:
                        type: object
                        properties:
                          busiest: {$ref: '#/components/schemas/Priority'}
                          open: {$ref: '#/components/schemas/Count'}
        components:
          schemas:
            Priority: {type: string, enum: [low, high]}
            Count: {type: integer}
            Tags: {type: array, items: {type: string}}
            PriorityAlias: {$ref: '#/components/schemas/Priority'}
            Ticket:
              type: object
              properties:
                id: {type: string}
                priority: {$ref: '#/components/schemas/Priority'}
                aliased: {$ref: '#/components/schemas/PriorityAlias'}
                votes: {$ref: '#/components/schemas/Count'}
                tags: {$ref: '#/components/schemas/Tags'}
        """

    @Test func omittedFieldsTypedByScalarRefsAreGenerated() async throws {
        let seed = """
            version: 1
            data:
              Ticket:
                - {id: t1}
            """
        let engine = try await MockRESTEngine(spec: .yaml(Self.scalarRefSpec), seed: .yaml(seed), serverSeed: 3)
        let first = await engine.execute(RESTRequest(method: "GET", path: "/tickets/t1"))
        let priority = try #require(first.body?["priority"].enumName)
        #expect(["low", "high"].contains(priority))
        let aliased = try #require(first.body?["aliased"].enumName)
        #expect(["low", "high"].contains(aliased))
        #expect(first.body?["votes"].intValue != nil)
        #expect(first.body?["tags"] == .list([]))

        let second = await engine.execute(RESTRequest(method: "GET", path: "/tickets/t1"))
        #expect(second.body == first.body)
    }

    @Test func synthesizedResponsesFollowScalarRefs() async throws {
        let engine = try await MockRESTEngine(spec: .yaml(Self.scalarRefSpec), serverSeed: 3)
        let count = await engine.execute(RESTRequest(method: "GET", path: "/open-count"))
        #expect(count.body?.intValue != nil)

        let summary = await engine.execute(RESTRequest(method: "GET", path: "/summary"))
        let busiest = try #require(summary.body?["busiest"].enumName)
        #expect(["low", "high"].contains(busiest))
        #expect(summary.body?["open"].intValue != nil)
    }

    // MARK: - Spec files

    @Test func specsLoadFromYAMLAndJSONFiles() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mockrest-spec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let yamlFile = directory.appendingPathComponent("things.yaml")
        try Self.thingSpec.write(to: yamlFile, atomically: true, encoding: .utf8)
        let fromYAML = try await MockRESTEngine(spec: .file(yamlFile.path))
        #expect(await fromYAML.execute(RESTRequest(method: "GET", path: "/things")).status == 200)

        let jsonFile = directory.appendingPathComponent("ping.json")
        let json = """
            {"openapi": "3.0.3", "info": {"title": "Ping", "version": "1"},
             "paths": {"/ping": {"get": {"responses": {"200": {"description": "ok",
               "content": {"application/json": {"example": {"pong": true}}}}}}}}}
            """
        try json.write(to: jsonFile, atomically: true, encoding: .utf8)
        let fromJSON = try await MockRESTEngine(spec: .file(jsonFile.path))
        #expect(await fromJSON.execute(RESTRequest(method: "GET", path: "/ping")).body?["pong"] == .bool(true))
    }

    @Test func aMissingSpecFileNamesThePathItTried() async {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("mockrest-missing-\(UUID().uuidString).yaml").path
        do {
            _ = try await MockRESTEngine(spec: .file(path))
            Issue.record("Expected a schema error")
        } catch let error as MockError {
            #expect(error.category == .schema)
            #expect(error.message.contains("Cannot read spec file"))
            #expect(error.sourceName == path)
        } catch {
            Issue.record("Expected a MockError, got \(error)")
        }
    }
}
