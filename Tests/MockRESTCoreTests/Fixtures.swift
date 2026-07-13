import MockRESTCore

/// The shop spec + seed shared across engine tests.
struct Fixtures {
    static let shopSpec = """
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
            put:
              requestBody:
                content:
                  application/json:
                    schema: {$ref: '#/components/schemas/User'}
              responses:
                '200':
                  description: replaced
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
          /products:
            get:
              responses:
                '200':
                  description: envelope list
                  content:
                    application/json:
                      schema:
                        type: object
                        properties:
                          items: {type: array, items: {$ref: '#/components/schemas/Product'}}
                          total: {type: integer}
                          offset: {type: integer}
          /products/{id}:
            parameters:
              - {name: id, in: path, required: true, schema: {type: string}}
            get:
              responses:
                '200':
                  description: one
                  content:
                    application/json:
                      schema: {$ref: '#/components/schemas/Product'}
          /status:
            get:
              responses:
                '200':
                  description: health
                  content:
                    application/json:
                      schema:
                        type: object
                        properties:
                          state: {type: string, enum: [ok, degraded]}
                          uptime: {type: integer}
          /motd:
            get:
              responses:
                '200':
                  description: message of the day
                  content:
                    application/json:
                      example: {message: Welcome!}
        components:
          schemas:
            User:
              type: object
              required: [id, name, email]
              example: {id: seed-user, name: Example User, email: example@example.com}
              properties:
                id: {type: string}
                name: {type: string}
                email: {type: string, format: email}
                phone: {type: string}
                status: {type: string, enum: [active, suspended]}
            Product:
              type: object
              required: [id, name]
              properties:
                id: {type: string}
                name: {type: string}
                priceCents: {type: integer}
            Cart:
              type: object
              properties:
                id: {type: string}
                owner: {$ref: '#/components/schemas/User'}
                items: {type: array, items: {$ref: '#/components/schemas/Product'}}
        """

    static let shopSeed = """
        version: 1
        data:
          User:
            - {id: u1, name: Avery Quinn, email: avery@example.com, status: active}
            - {id: u2, name: Blake Chen, email: blake@example.com}
          Product:
            - {id: p1, name: Espresso Machine, priceCents: 64900}
            - {id: p2, name: Grinder, priceCents: 12900}
          Cart:
            - {id: c1, owner: u1, items: [p1, p2]}
        """

    /// An engine over the shop spec + seed.
    static func shopEngine(
        options: MockRESTOptions = MockRESTOptions(),
        @MockRESTBuilder configure: () -> [any MockRESTDeclaration] = { [] }
    ) async throws -> MockRESTEngine {
        try await MockRESTEngine(
            spec: .yaml(shopSpec),
            seed: .yaml(shopSeed),
            serverSeed: 7,
            options: options,
            configuration: configure
        )
    }
}
