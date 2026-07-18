import MockCore

/// The transport-independent MockREST engine: a validated spec and/or endpoint DSL, seeded
/// in-memory state, auto-wired CRUD, and deterministic response synthesis.
///
/// Use the engine directly for in-process execution (no networking), or wrap it in
/// `MockRESTServer` from the `MockREST` module — or register it on a shared `MockHost` next to
/// sibling protocol mocks.
public final class MockRESTEngine: Sendable {
    /// The engine's state store. Pass a shared store at init to make REST mutations visible to
    /// sibling protocol mocks (and vice versa).
    public let store: StateStore

    private let routes: [EngineRoute]
    private let options: MockRESTOptions
    private let synthesizer: ResponseSynthesizer
    private let faults = FaultQueue()

    /// Creates an engine.
    ///
    /// Everything is validated here — spec, seed, resources, generator bindings, endpoint
    /// templates — so a misconfigured engine never serves a request.
    ///
    /// - Parameters:
    ///   - spec: The OpenAPI 3.0/3.1 document to mock; omit for DSL-only mode.
    ///   - seed: Initial state (`version` / `data` / `resources`), validated before startup.
    ///   - generators: Generators keyed by `"Schema.field"` for fields absent from seed data.
    ///   - serverSeed: Seed for deterministic data generation; equal seeds generate equal data.
    ///   - options: Latency, auth simulation, and CORS behavior.
    ///   - store: The state store to use — pass the sibling services' store to share state.
    ///   - configuration: Endpoints and resource declarations.
    public init(
        spec specSource: SpecSource? = nil,
        seed seedSource: SeedSource? = nil,
        generators: [String: FieldGenerator] = [:],
        serverSeed: UInt64 = 0,
        options: MockRESTOptions = MockRESTOptions(),
        store: StateStore? = nil,
        @MockRESTBuilder configuration: () -> [any MockRESTDeclaration] = { [] }
    ) async throws {
        let spec = try specSource.map { try SpecLoader.load($0) }
        let declarations = configuration()
        self.options = options

        let registry = GeneratorRegistry(bindings: generators, serverSeed: serverSeed)
        if let spec {
            try Self.validate(generatorKeys: registry.bindingKeys, against: spec)
        }
        let synthesizer = ResponseSynthesizer(spec: spec, generators: registry)
        self.synthesizer = synthesizer

        // Assemble resources: spec inference first, overridden by the seed's `resources:`
        // block, overridden by DSL `Resource` declarations.
        let rawSeed = try seedSource.map { try $0.rawDocument() }
        var resourcesByName: [String: ResourceModel] = [:]
        var resourceOrder: [String] = []
        func adopt(_ resource: ResourceModel) {
            if resourcesByName[resource.name] == nil {
                resourceOrder.append(resource.name)
            }
            resourcesByName[resource.name] = resource
        }
        if let spec {
            for resource in ResourceInference.infer(from: spec) {
                adopt(resource)
            }
        }
        if let rawSeed {
            for resource in try RESTSeedLoader.declaredResources(
                in: rawSeed, spec: spec, sourceName: seedSource?.sourceName)
            {
                adopt(resource)
            }
        }
        for declaration in declarations {
            guard let declared = declaration as? Resource else { continue }
            adopt(
                ResourceModel(
                    name: declared.name,
                    schema: declared.schema,
                    basePath: declared.path,
                    idField: declared.idField,
                    listEnvelope: nil
                )
            )
        }
        let resources = resourceOrder.compactMap { resourcesByName[$0] }
        try Self.validate(resources: resources, spec: spec)

        // Seed the store: explicit data first, then schema examples for schemas with no data.
        var data = StoreData()
        if let rawSeed {
            data = try RESTSeedLoader.load(
                document: rawSeed,
                spec: spec,
                resources: resources,
                sourceName: seedSource?.sourceName
            )
        }
        if let spec {
            try Self.seedExamples(from: spec, into: &data, resources: resources)
        }
        if let shared = store {
            // A shared store may already hold a sibling service's seed; merge, don't replace.
            await shared.merge(data)
            self.store = shared
        } else {
            let own = StateStore()
            await own.load(data)
            self.store = own
        }

        // Route table: spec synthesis first, auto-CRUD overwrites it for collections, DSL
        // endpoints overwrite everything.
        var table: [String: EngineRoute] = [:]
        var order: [String] = []
        func register(_ route: EngineRoute) {
            let key = "\(route.method) \(route.pattern.template)"
            if table[key] == nil {
                order.append(key)
            }
            table[key] = route
        }
        if let spec {
            for operation in spec.operations {
                register(Self.synthesisRoute(for: operation, synthesizer: synthesizer, spec: spec))
            }
        }
        let specOperationKeys = Set((spec?.operations ?? []).map { "\($0.method) \($0.pattern.template)" })
        for resource in resources {
            let crud = AutoCRUD(resource: resource, spec: spec, synthesizer: synthesizer)
            for route in try crud.routes() {
                let key = "\(route.method) \(route.pattern.template)"
                // Spec-inferred collections only get the operations the spec declares;
                // explicitly declared resources get the full conventional set.
                if !resource.inferred || specOperationKeys.contains(key) {
                    register(route)
                }
            }
        }
        for declaration in declarations {
            guard let endpoint = declaration.asEndpoint else { continue }
            let pattern: RoutePattern
            do {
                pattern = try RoutePattern(parsing: endpoint.path)
            } catch let error as MockError {
                throw MockError(
                    category: .configuration,
                    message: "\(endpoint.method) endpoint: \(error.message)"
                )
            }
            register(EngineRoute(method: endpoint.method, pattern: pattern, handler: endpoint.handler))
        }
        self.routes = order.compactMap { table[$0] }
            .sorted { RoutePattern.moreSpecific($0.pattern, $1.pattern) }
    }

    // MARK: - Execution

    /// Whether any route matches the path — the engine's `claims(_:)` seam. Any method counts,
    /// so mismatched methods get a diagnostic 405 instead of the host's 404.
    public func matches(path: String) -> Bool {
        routes.contains { $0.pattern.match(path) != nil }
    }

    /// Executes a request and returns the response. Never throws — handler errors become
    /// 5xx responses.
    public func execute(_ request: RESTRequest) async -> RESTResponse {
        if let delay = options.delay {
            try? await Task.sleep(for: delay)
        }
        if request.method == "OPTIONS", options.cors {
            return preflight(request)
        }
        if let tokens = options.bearerTokens {
            let provided = request.header("Authorization").flatMap { header -> String? in
                header.hasPrefix("Bearer ") ? String(header.dropFirst("Bearer ".count)) : nil
            }
            guard let provided, tokens.contains(provided) else {
                var response = RESTResponse.errors(
                    status: 401,
                    [(message: "Missing or invalid bearer token", path: nil)]
                )
                response.headers.append(("WWW-Authenticate", "Bearer"))
                return decorate(response, for: request)
            }
        }
        if let accept = request.header("Accept"), !Self.acceptsJSON(accept) {
            return decorate(
                .errors(status: 406, [(message: "MockREST serves application/json only", path: nil)]),
                for: request
            )
        }
        var allowed: [String] = []
        for route in routes {
            guard let params = route.pattern.match(request.path) else { continue }
            guard route.method == request.method else {
                if !allowed.contains(route.method) {
                    allowed.append(route.method)
                }
                continue
            }
            // Injected faults consume only requests that actually matched a route — a CORS
            // preflight or a stray 404 must not eat the failure a test queued for its real call.
            if let status = await faults.next() {
                return decorate(
                    .errors(status: status, [(message: "Injected failure (failNext)", path: nil)]),
                    for: request
                )
            }
            let matched = request.with(pathParams: params)
            do {
                let handler = route.handler
                var response = try await store.withMutationState { state in
                    try handler(matched, &state)
                }
                // References resolve on the way out, whatever handler produced the body.
                if let body = response.body {
                    response.body = synthesizer.resolveReferences(body, data: await store.snapshot())
                }
                return decorate(response, for: request)
            } catch let error as MockError {
                return decorate(
                    .errors(status: 500, [(message: error.message, path: error.documentPath)]),
                    for: request
                )
            } catch {
                return decorate(
                    .errors(status: 500, [(message: String(describing: error), path: nil)]),
                    for: request
                )
            }
        }
        if !allowed.isEmpty {
            var response = RESTResponse.errors(
                status: 405,
                [
                    (
                        message:
                            "\(request.method) is not supported here (allowed: \(allowed.joined(separator: ", ")))",
                        path: nil
                    )
                ]
            )
            response.headers.append(("Allow", allowed.joined(separator: ", ")))
            return decorate(response, for: request)
        }
        return decorate(
            .errors(status: 404, [(message: "No route matches \(request.method) \(request.path)", path: nil)]),
            for: request
        )
    }

    /// Forces the next `count` matched requests to fail with the given status — for testing
    /// error UI.
    public func failNext(status: Int, count: Int = 1) async {
        await faults.enqueue(status: status, count: count)
    }

    // MARK: - Cross-cutting

    private func preflight(_ request: RESTRequest) -> RESTResponse {
        var methods: [String] = []
        for route in routes where route.pattern.match(request.path) != nil {
            if !methods.contains(route.method) {
                methods.append(route.method)
            }
        }
        var response = RESTResponse(status: 204)
        response.headers = [
            ("Access-Control-Allow-Origin", request.header("Origin") ?? "*"),
            ("Access-Control-Allow-Methods", (methods + ["OPTIONS"]).joined(separator: ", ")),
            ("Access-Control-Allow-Headers", request.header("Access-Control-Request-Headers") ?? "*"),
            ("Access-Control-Max-Age", "600"),
        ]
        return response
    }

    /// Adds CORS headers to a response when enabled and the request is cross-origin.
    private func decorate(_ response: RESTResponse, for request: RESTRequest) -> RESTResponse {
        guard options.cors, let origin = request.header("Origin") else { return response }
        var decorated = response
        decorated.headers.append(("Access-Control-Allow-Origin", origin))
        return decorated
    }

    private static func acceptsJSON(_ accept: String) -> Bool {
        let lowered = accept.lowercased()
        return lowered.contains("json") || lowered.contains("*/*") || lowered.contains("application/*")
    }

    // MARK: - Startup validation

    /// A synthesis handler for a spec operation with no stored collection behind it: serves the
    /// declared example, else a stable generated body from the response schema.
    private static func synthesisRoute(
        for operation: SpecOperation,
        synthesizer: ResponseSynthesizer,
        spec: RESTSpec
    ) -> EngineRoute {
        let pseudoType = "\(operation.method) \(operation.pattern.template)"
        return EngineRoute(method: operation.method, pattern: operation.pattern) { request, state in
            // The spec's declared request body is enforced even without a stored collection
            // behind the route.
            if let bodySchema = operation.requestBody {
                if request.body.isNull {
                    if operation.requestBodyRequired {
                        return .errors(status: 422, [(message: "A request body is required", path: "body")])
                    }
                } else {
                    let coercion = SchemaCoercion(
                        spec: spec, category: .seed, sourceName: nil, recordReference: { _, _, _ in })
                    do {
                        _ = try coercion.coerce(request.body, to: bodySchema, at: "body")
                    } catch let error as MockError {
                        return .errors(status: 422, [(message: error.message, path: error.documentPath)])
                    }
                }
            }
            if let example = operation.responseExample {
                return .status(operation.successStatus, body: example)
            }
            guard let schema = operation.responseSchema else {
                return .status(operation.successStatus)
            }
            let body = synthesizer.synthesize(
                node: schema,
                pseudoType: pseudoType,
                fieldName: "response",
                data: state.storeData
            )
            return .status(operation.successStatus, body: body)
        }
    }

    private static func validate(generatorKeys: [String], against spec: RESTSpec) throws {
        for key in generatorKeys {
            let parts = key.split(separator: ".", maxSplits: 1).map(String.init)
            guard parts.count == 2 else {
                throw MockError(
                    category: .configuration,
                    message: "Generator key '\(key)' must have the form 'Schema.field'"
                )
            }
            let (schemaName, fieldName) = (parts[0], parts[1])
            guard let properties = spec.objectProperties(of: schemaName) else {
                let objectNames = spec.schemas.keys.filter { spec.objectProperties(of: $0) != nil }
                let clause = Suggestion.clause(for: schemaName, in: objectNames)
                throw MockError(
                    category: .configuration,
                    message: "Generator '\(key)' refers to unknown object schema '\(schemaName)'.\(clause)"
                )
            }
            guard properties[fieldName] != nil else {
                let clause = Suggestion.clause(for: fieldName, in: properties.keys)
                throw MockError(
                    category: .configuration,
                    message: "Generator '\(key)' refers to unknown field '\(fieldName)' on '\(schemaName)'.\(clause)"
                )
            }
        }
    }

    private static func validate(resources: [ResourceModel], spec: RESTSpec?) throws {
        for resource in resources {
            let pattern = try RoutePattern(parsing: resource.basePath)
            guard pattern.parameterNames.isEmpty else {
                throw MockError(
                    category: .configuration,
                    message: "Resource '\(resource.name)' path '\(resource.basePath)' cannot contain parameters"
                )
            }
            guard let spec else { continue }
            guard let properties = spec.objectProperties(of: resource.schema) else {
                let objectNames = spec.schemas.keys.filter { spec.objectProperties(of: $0) != nil }
                let clause = Suggestion.clause(for: resource.schema, in: objectNames)
                throw MockError(
                    category: .configuration,
                    message: "Resource '\(resource.name)' names unknown object schema '\(resource.schema)'.\(clause)"
                )
            }
            guard properties[resource.idField] != nil else {
                let clause = Suggestion.clause(for: resource.idField, in: properties.keys)
                throw MockError(
                    category: .configuration,
                    message: "Resource '\(resource.name)': schema '\(resource.schema)' has no "
                        + "'\(resource.idField)' field.\(clause)"
                )
            }
        }
    }

    /// Seeds one record from each object schema's `example` when nothing seeded that schema
    /// explicitly (explicit seeds always win).
    private static func seedExamples(from spec: RESTSpec, into data: inout StoreData, resources: [ResourceModel])
        throws
    {
        for (schemaName, example) in spec.schemaExamples.sorted(by: { $0.key < $1.key }) {
            guard data.allRecords(type: schemaName).isEmpty else { continue }
            guard let fields = example.objectValue else { continue }
            guard case .object = spec.schemas[schemaName] else { continue }
            let coercion = SchemaCoercion(
                spec: spec,
                category: .schema,
                sourceName: nil,
                recordReference: { _, _, _ in }
            )
            let idField = resources.first { $0.schema == schemaName }?.idField ?? "id"
            let coerced: [String: MockValue]
            do {
                coerced = try coercion.coerceRecord(
                    fields,
                    schemaName: schemaName,
                    at: "components.schemas.\(schemaName).example",
                    idField: idField
                )
            } catch let error as MockError {
                throw MockError(
                    category: .schema,
                    message: "Schema example does not match its own schema: \(error.message)",
                    documentPath: error.documentPath
                )
            }
            var record = coerced
            if let id = record[idField]?.stringValue {
                record["id"] = .string(id)
            } else if let number = record[idField]?.intValue {
                record[idField] = .string(String(number))
                record["id"] = .string(String(number))
            }
            data.insert(type: schemaName, fields: record)
        }
    }
}
