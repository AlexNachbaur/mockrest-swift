import MockRESTCore
import Testing

/// What the spec says a request must look like is enforced all the way down: nested objects,
/// array elements, union positions, and required parameters.
@Suite struct RequestValidationTests {
    static let orderSpec = """
        openapi: 3.0.3
        info: {title: Orders, version: 1.0.0}
        paths:
          /orders:
            get:
              responses:
                '200':
                  description: list
                  content:
                    application/json:
                      schema: {type: array, items: {$ref: '#/components/schemas/Order'}}
            post:
              requestBody:
                required: true
                content:
                  application/json:
                    schema: {$ref: '#/components/schemas/Order'}
              responses:
                '201':
                  description: created
                  content:
                    application/json:
                      schema: {$ref: '#/components/schemas/Order'}
          /orders/{id}:
            parameters:
              - {name: id, in: path, required: true, schema: {type: string}}
            get:
              responses:
                '200':
                  description: one
                  content:
                    application/json:
                      schema: {$ref: '#/components/schemas/Order'}
            patch:
              requestBody:
                content:
                  application/json:
                    schema: {$ref: '#/components/schemas/Order'}
              responses:
                '200':
                  description: merged
                  content:
                    application/json:
                      schema: {$ref: '#/components/schemas/Order'}
          /search:
            get:
              parameters:
                - {name: q, in: query, required: true, schema: {type: string}}
                - {name: X-Tenant, in: header, required: true, schema: {type: string}}
                - {name: Authorization, in: header, required: true, schema: {type: string}}
                - {name: page, in: query, schema: {type: integer}}
              responses:
                '200':
                  description: results
                  content:
                    application/json:
                      example: {hits: 0}
          /quotes:
            post:
              requestBody:
                required: true
                content:
                  application/json:
                    schema:
                      type: object
                      required: [destination]
                      properties:
                        destination: {$ref: '#/components/schemas/Address'}
              responses:
                '200': {description: ok}
        components:
          schemas:
            Address:
              type: object
              required: [city]
              properties:
                city: {type: string}
                street: {type: string}
            Card:
              type: object
              required: [number]
              properties:
                number: {type: string}
            Bank:
              type: object
              required: [iban]
              properties:
                iban: {type: string}
            Order:
              type: object
              required: [id, address]
              properties:
                id: {type: string}
                address: {$ref: '#/components/schemas/Address'}
                lines:
                  type: array
                  items:
                    type: object
                    required: [sku]
                    properties:
                      sku: {type: string}
                      quantity: {type: integer}
                payment:
                  oneOf:
                    - {$ref: '#/components/schemas/Card'}
                    - {$ref: '#/components/schemas/Bank'}
        """

    private func post(_ engine: MockRESTEngine, _ path: String, _ body: MockValue) async -> RESTResponse {
        await engine.execute(RESTRequest(method: "POST", path: path, body: body))
    }

    private func firstError(_ response: RESTResponse) -> (message: String, path: String?) {
        let entry = response.body?["errors"][0] ?? .null
        return (entry["message"].stringValue ?? "", entry["path"].stringValue)
    }

    // MARK: - Nested required

    @Test func embeddedObjectsEnforceTheirRequiredFields() async throws {
        let engine = try await MockRESTEngine(spec: .yaml(Self.orderSpec))
        let response = await post(engine, "/orders", ["address": ["street": "1 Main St"]])
        #expect(response.status == 422)
        #expect(firstError(response).message == "Missing required field 'city' of 'Address'")
        #expect(firstError(response).path == "body.address")
    }

    @Test func arrayElementsEnforceTheirRequiredFields() async throws {
        let engine = try await MockRESTEngine(spec: .yaml(Self.orderSpec))
        let response = await post(
            engine, "/orders",
            ["address": ["city": "Oslo"], "lines": [["sku": "A-1"], ["quantity": 2]]])
        #expect(response.status == 422)
        #expect(firstError(response).message == "Missing required field 'sku'")
        #expect(firstError(response).path == "body.lines[1]")
    }

    @Test func inlineBodySchemasEnforceRequiredOnNestedRefs() async throws {
        let engine = try await MockRESTEngine(spec: .yaml(Self.orderSpec))
        let invalid = await post(engine, "/quotes", ["destination": ["street": "1 Main St"]])
        #expect(invalid.status == 422)
        #expect(firstError(invalid).path == "body.destination")
        let valid = await post(engine, "/quotes", ["destination": ["city": "Oslo"]])
        #expect(valid.status == 200)
    }

    @Test func completeNestedBodiesAreAccepted() async throws {
        let engine = try await MockRESTEngine(spec: .yaml(Self.orderSpec))
        let response = await post(
            engine, "/orders",
            ["id": "o1", "address": ["city": "Oslo"], "lines": [["sku": "A-1", "quantity": 2]]])
        #expect(response.status == 201)
        #expect(response.body?["lines"][0]["sku"] == .string("A-1"))
    }

    @Test func patchAndSeedsStillSkipRequired() async throws {
        let seed = """
            version: 1
            data:
              Order:
                - {id: o1, address: {street: 1 Main St}}
            """
        let engine = try await MockRESTEngine(spec: .yaml(Self.orderSpec), seed: .yaml(seed))
        let patched = await engine.execute(
            RESTRequest(method: "PATCH", path: "/orders/o1", body: ["address": ["street": "2 Side St"]]))
        #expect(patched.status == 200)
        #expect(patched.body?["address"]["street"] == .string("2 Side St"))
    }

    // MARK: - Union positions

    @Test func objectsInOneOfPositionsValidateAgainstTheMatchingVariant() async throws {
        let engine = try await MockRESTEngine(spec: .yaml(Self.orderSpec))
        let card = await post(
            engine, "/orders", ["id": "o1", "address": ["city": "Oslo"], "payment": ["number": "4111"]])
        #expect(card.status == 201)
        #expect(card.body?["payment"]["number"] == .string("4111"))

        let bank = await post(
            engine, "/orders", ["id": "o2", "address": ["city": "Oslo"], "payment": ["iban": "NO93"]])
        #expect(bank.status == 201)
        let fetched = await engine.execute(RESTRequest(method: "GET", path: "/orders/o2"))
        #expect(fetched.body?["payment"]["iban"] == .string("NO93"))
    }

    @Test func objectsMatchingNoVariantSayWhyForEachOne() async throws {
        let engine = try await MockRESTEngine(spec: .yaml(Self.orderSpec))
        let response = await post(
            engine, "/orders", ["address": ["city": "Oslo"], "payment": ["wallet": "abc"]])
        #expect(response.status == 422)
        let error = firstError(response)
        #expect(error.path == "body.payment")
        #expect(error.message.contains("matches none of the possible schemas here (Card, Bank)"))
        #expect(error.message.contains("Card: Unknown field 'wallet' on 'Card'"))
        #expect(error.message.contains("Bank: Unknown field 'wallet' on 'Bank'"))
    }

    // MARK: - Required parameters

    @Test func requiredQueryAndHeaderParametersAreEnforced() async throws {
        let engine = try await MockRESTEngine(spec: .yaml(Self.orderSpec))
        let noQuery = await engine.execute(
            RESTRequest(method: "GET", path: "/search", headers: [("X-Tenant", "acme")]))
        #expect(noQuery.status == 400)
        #expect(firstError(noQuery).message == "Missing required query parameter 'q'")
        #expect(firstError(noQuery).path == "query.q")

        let noHeader = await engine.execute(
            RESTRequest(method: "GET", path: "/search", query: [("q", "tea")]))
        #expect(noHeader.status == 400)
        #expect(firstError(noHeader).message == "Missing required header parameter 'X-Tenant'")
        #expect(firstError(noHeader).path == "header.X-Tenant")

        // Header names are case-insensitive; optional parameters and the Authorization header
        // (which OpenAPI says to ignore as a parameter) are not demanded.
        let complete = await engine.execute(
            RESTRequest(method: "GET", path: "/search", query: [("q", "tea")], headers: [("x-tenant", "acme")]))
        #expect(complete.status == 200)
    }

    @Test func aHandWrittenEndpointDecidesItsOwnParameters() async throws {
        let engine = try await MockRESTEngine(spec: .yaml(Self.orderSpec)) {
            Get("/search") { _, _ in .ok(["custom": true]) }
        }
        let response = await engine.execute(RESTRequest(method: "GET", path: "/search"))
        #expect(response.body?["custom"] == .bool(true))
    }
}
