import Foundation
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
    /// The initializer runs on the caller's actor, so the configuration block can be written
    /// inline from a `@MainActor` context (an XCUITest `setUp`, say) and capture whatever that
    /// context can see; only the handler closures inside it must be `@Sendable`.
    ///
    /// - Parameters:
    ///   - spec: The OpenAPI 3.0/3.1 document to mock; omit for DSL-only mode.
    ///   - seed: Initial state (`version` / `data` / `resources`), validated before startup.
    ///   - generators: Generators for fields absent from stored records, keyed by
    ///     `"Schema.field"` with a spec and by `"resource.field"` in DSL-only mode.
    ///   - serverSeed: Seed for deterministic data generation; equal seeds generate equal data.
    ///   - options: Latency, auth simulation, and CORS behavior.
    ///   - store: The state store to use — pass the sibling services' store to share state.
    ///   - configuration: Endpoints and resource declarations.
    nonisolated(nonsending) public init(
        spec: SpecSource? = nil,
        seed: SeedSource? = nil,
        generators: [String: FieldGenerator] = [:],
        serverSeed: UInt64 = 0,
        options: MockRESTOptions = MockRESTOptions(),
        store: StateStore? = nil,
        @MockRESTBuilder configuration: () -> [any MockRESTDeclaration] = { [] }
    ) async throws {
        let seedSource = seed
        let spec = try spec.map { try SpecLoader.load($0) }
        let declarations = configuration()
        self.options = options

        if let spec {
            try Self.validate(generatorKeys: generators.keys.sorted(), against: spec)
        }

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

        // Generators: with a spec the keys were checked against its schemas above; without
        // one they name declared resources, which is also what says which fields to fill.
        var bindings = generators
        var boundFields: [String: [String]] = [:]
        if spec == nil {
            (bindings, boundFields) = try Self.resourceBindings(generators, resources: resources)
        }
        let synthesizer = ResponseSynthesizer(
            spec: spec,
            generators: GeneratorRegistry(bindings: bindings, serverSeed: serverSeed),
            boundFields: boundFields
        )
        self.synthesizer = synthesizer

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
        // endpoints overwrite everything. Routes are keyed by method + template *shape*, so
        // `Get("/users/{userId}")` replaces the spec's `/users/{id}` — the two match exactly
        // the same requests, and keeping both would leave the winner to a tiebreak.
        var table: [String: EngineRoute] = [:]
        var order: [String] = []
        func key(_ method: String, _ pattern: RoutePattern) -> String {
            "\(method) \(pattern.shape)"
        }
        func register(_ route: EngineRoute) {
            let routeKey = key(route.method, route.pattern)
            if table[routeKey] == nil {
                order.append(routeKey)
            }
            table[routeKey] = route
        }
        var specOperations: [String: SpecOperation] = [:]
        if let spec {
            for operation in spec.operations {
                specOperations[key(operation.method, operation.pattern)] = operation
                var route = Self.synthesisRoute(for: operation, synthesizer: synthesizer, spec: spec)
                route.handler = Self.enforcingRequiredParameters(of: operation, route.handler)
                register(route)
            }
        }
        for resource in resources {
            let crud = AutoCRUD(resource: resource, spec: spec, synthesizer: synthesizer)
            for var route in try crud.routes() {
                let operation = specOperations[key(route.method, route.pattern)]
                // Spec-inferred collections only get the operations the spec declares;
                // explicitly declared resources get the full conventional set.
                guard !resource.inferred || operation != nil else { continue }
                if let operation {
                    route.handler = Self.enforcingRequiredParameters(of: operation, route.handler)
                }
                register(route)
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
    ///
    /// `HEAD` is answered by the matching `GET` route (unless a `HEAD` endpoint is declared)
    /// with the body dropped. A request whose task is cancelled while waiting out the
    /// configured delay gets a `503` and never reaches its handler.
    public func execute(_ request: RESTRequest) async -> RESTResponse {
        await execute(request, keepingHeadBody: false)
    }

    /// Executes a request. With `keepingHeadBody`, a `HEAD` response keeps the body its `GET`
    /// would have sent, so an HTTP transport can report the right `Content-Length` before
    /// dropping it.
    package func execute(_ request: RESTRequest, keepingHeadBody: Bool) async -> RESTResponse {
        if let delay = options.delay {
            do {
                try await Task.sleep(for: delay)
            } catch {
                // Cancelled mid-delay: nobody is waiting for the answer, so the handler (and
                // any state change it would make) must not run.
                return decorate(
                    .errors(status: 503, [(message: "Request cancelled during the configured delay", path: nil)]),
                    for: request
                )
            }
        }
        if request.method == "OPTIONS", options.cors {
            return preflight(request)
        }
        var response = decorate(await dispatch(request), for: request)
        if request.method == "HEAD", !keepingHeadBody, response.body != nil {
            response.body = nil
            if !response.headers.contains(where: { $0.name.lowercased() == "content-type" }) {
                response.headers.append(("Content-Type", "application/json"))
            }
        }
        return response
    }

    /// Authenticates, negotiates, routes, and runs the handler — everything but the
    /// cross-cutting decoration.
    private func dispatch(_ request: RESTRequest) async -> RESTResponse {
        if let tokens = options.bearerTokens {
            guard let provided = Self.bearerToken(in: request.header("Authorization")), tokens.contains(provided)
            else {
                var response = RESTResponse.errors(
                    status: 401,
                    [(message: "Missing or invalid bearer token", path: nil)]
                )
                response.headers.append(("WWW-Authenticate", "Bearer"))
                return response
            }
        }
        if let accept = request.header("Accept"), !Self.acceptsJSON(accept) {
            return .errors(status: 406, [(message: "MockREST serves application/json only", path: nil)])
        }
        let matching = routes.compactMap { route -> (route: EngineRoute, params: [String: String])? in
            route.pattern.match(request.path).map { (route, $0) }
        }
        // HEAD is GET without the body, unless an endpoint claims HEAD for itself.
        var method = request.method
        if method == "HEAD", !matching.contains(where: { $0.route.method == "HEAD" }) {
            method = "GET"
        }
        guard let (route, params) = matching.first(where: { $0.route.method == method }) else {
            guard !matching.isEmpty else {
                return .errors(
                    status: 404, [(message: "No route matches \(request.method) \(request.path)", path: nil)])
            }
            let allowed = Self.allowedMethods(matching.map(\.route.method))
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
            return response
        }
        // Injected faults consume only requests that actually matched a route — a CORS
        // preflight or a stray 404 must not eat the failure a test queued for its real call.
        if let status = await faults.next() {
            return .errors(status: status, [(message: "Injected failure (failNext)", path: nil)])
        }
        let matched = request.with(pathParams: params)
        do {
            let handler = route.handler
            let synthesizer = synthesizer
            // References resolve on the way out, whatever handler produced the body — inside
            // the same transaction, so the response is one consistent view of the state the
            // handler saw and wrote, not a later one another request has already changed.
            return try await store.withMutationState { state in
                var response = try handler(matched, &state)
                if let body = response.body {
                    response.body = synthesizer.resolveReferences(body, data: state.storeData)
                }
                return response
            }
        } catch let error as MockError {
            return .errors(status: 500, [(message: error.message, path: error.documentPath)])
        } catch {
            return .errors(status: 500, [(message: String(describing: error), path: nil)])
        }
    }

    /// Forces the next `count` matched requests to fail with the given status — for testing
    /// error UI.
    public func failNext(status: Int, count: Int = 1) async {
        await faults.enqueue(status: status, count: count)
    }

    // MARK: - Cross-cutting

    private func preflight(_ request: RESTRequest) -> RESTResponse {
        let methods = Self.allowedMethods(
            routes.filter { $0.pattern.match(request.path) != nil }.map(\.method))
        var response = RESTResponse(status: 204)
        response.headers = [
            ("Access-Control-Allow-Origin", request.header("Origin") ?? "*"),
            ("Access-Control-Allow-Methods", (methods + ["OPTIONS"]).joined(separator: ", ")),
            ("Access-Control-Allow-Headers", request.header("Access-Control-Request-Headers") ?? "*"),
            ("Access-Control-Max-Age", "600"),
        ]
        if request.header("Origin") != nil {
            // The answer echoes the request's origin and requested headers, so a cache must
            // not replay it for a different one.
            response.headers.append(("Vary", "Origin, Access-Control-Request-Headers"))
        }
        return response
    }

    /// Adds CORS headers to a response when enabled and the request is cross-origin.
    private func decorate(_ response: RESTResponse, for request: RESTRequest) -> RESTResponse {
        guard options.cors, let origin = request.header("Origin") else { return response }
        var decorated = response
        // Browsers hide every non-safelisted response header from scripts unless it is exposed —
        // without this a web client could not read `Location` after a create.
        var exposed: [String] = []
        for header in response.headers where !exposed.contains(where: { $0.lowercased() == header.name.lowercased() }) {
            exposed.append(header.name)
        }
        decorated.headers.append(("Access-Control-Allow-Origin", origin))
        // The allowed origin is an echo of the request's, so caches must key on it.
        decorated.headers.append(("Vary", "Origin"))
        if !exposed.isEmpty {
            decorated.headers.append(("Access-Control-Expose-Headers", exposed.joined(separator: ", ")))
        }
        return decorated
    }

    /// The distinct methods a path answers, in route order, with `HEAD` implied by `GET`.
    private static func allowedMethods(_ methods: [String]) -> [String] {
        var allowed: [String] = []
        for method in methods where !allowed.contains(method) {
            allowed.append(method)
        }
        if let get = allowed.firstIndex(of: "GET"), !allowed.contains("HEAD") {
            allowed.insert("HEAD", at: get + 1)
        }
        return allowed
    }

    /// The token of an `Authorization: Bearer <token>` header. The scheme name is
    /// case-insensitive (RFC 9110 §11.1), so `bearer` and `BEARER` are the same scheme.
    static func bearerToken(in header: String?) -> String? {
        guard let header else { return nil }
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard let space = trimmed.firstIndex(of: " "), trimmed[..<space].lowercased() == "bearer" else {
            return nil
        }
        let token = trimmed[space...].trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }

    /// Whether an `Accept` header admits `application/json`: some media range with a non-zero
    /// quality must be `*/*`, `application/*`, `application/json`, or a `+json` structured
    /// type. Ranges are compared whole — `text/x-json-not` is not JSON.
    static func acceptsJSON(_ accept: String) -> Bool {
        let ranges = accept.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // An empty header value expresses no preference.
        guard !ranges.isEmpty else { return true }
        return ranges.contains { range in
            let parts = range.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            guard let mediaType = parts.first else { return false }
            let refused = parts.dropFirst().contains { parameter in
                guard parameter.hasPrefix("q=") else { return false }
                return Double(parameter.dropFirst(2)) == 0
            }
            guard !refused else { return false }
            return mediaType == "*/*" || mediaType == "application/*" || mediaType == "application/json"
                || (mediaType.hasPrefix("application/") && mediaType.hasSuffix("+json"))
        }
    }

    /// Wraps a spec operation's handler so a request missing one of the operation's
    /// `required: true` query or header parameters is refused before the handler runs.
    private static func enforcingRequiredParameters(
        of operation: SpecOperation,
        _ handler: @escaping RESTHandler
    ) -> RESTHandler {
        // OpenAPI says header parameters named Accept, Content-Type, and Authorization are
        // ignored — those are described by other parts of the document.
        let ignoredHeaders: Set<String> = ["accept", "content-type", "authorization"]
        let required = operation.parameters.filter { parameter in
            guard parameter.required else { return false }
            switch parameter.location {
            case "query": return true
            case "header": return !ignoredHeaders.contains(parameter.name.lowercased())
            default: return false
            }
        }
        guard !required.isEmpty else { return handler }
        return { request, state in
            for parameter in required {
                let present =
                    parameter.location == "query"
                    ? request.queryValue(parameter.name) != nil
                    : request.header(parameter.name) != nil
                guard present else {
                    return .errors(
                        status: 400,
                        [
                            (
                                message: "Missing required \(parameter.location) parameter '\(parameter.name)'",
                                path: "\(parameter.location).\(parameter.name)"
                            )
                        ]
                    )
                }
            }
            return try handler(request, &state)
        }
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
                    // References in the body are checked against current state, matching
                    // AutoCRUD's request validation.
                    let snapshot = state
                    let dangling = DanglingReference()
                    let coercion = SchemaCoercion(
                        spec: spec,
                        category: .seed,
                        sourceName: nil,
                        recordReference: { typeName, id, referencePath in
                            if snapshot[typeName, id: id].isNull, dangling.first == nil {
                                dangling.first = (typeName, id, referencePath)
                            }
                        }
                    )
                    do {
                        _ = try coercion.coerceBody(request.body, to: bodySchema, at: "body")
                    } catch let error as MockError {
                        return .errors(status: 422, [(message: error.message, path: error.documentPath)])
                    }
                    if let (typeName, id, referencePath) = dangling.first {
                        return .errors(
                            status: 422,
                            [(message: "No '\(typeName)' record with id '\(id)'", path: referencePath)]
                        )
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

    /// DSL-only generator bindings: validates each `"resource.field"` key against the declared
    /// resources and re-keys it by the type its records are stored under.
    private static func resourceBindings(
        _ generators: [String: FieldGenerator],
        resources: [ResourceModel]
    ) throws -> (bindings: [String: FieldGenerator], boundFields: [String: [String]]) {
        var bindings: [String: FieldGenerator] = [:]
        var boundFields: [String: [String]] = [:]
        for key in generators.keys.sorted() {
            guard let generator = generators[key] else { continue }
            let parts = key.split(separator: ".", maxSplits: 1).map(String.init)
            guard parts.count == 2 else {
                throw MockError(
                    category: .configuration,
                    message: "Generator key '\(key)' must have the form 'resource.field'"
                )
            }
            let (resourceName, fieldName) = (parts[0], parts[1])
            guard let resource = resources.first(where: { $0.name == resourceName || $0.schema == resourceName })
            else {
                let clause = Suggestion.clause(for: resourceName, in: resources.map(\.name))
                throw MockError(
                    category: .configuration,
                    message: "Generator '\(key)' refers to unknown resource '\(resourceName)'; without a spec, "
                        + "generators are keyed by a declared resource.\(clause)"
                )
            }
            bindings["\(resource.schema).\(fieldName)"] = generator
            boundFields[resource.schema, default: []].append(fieldName)
        }
        return (bindings, boundFields)
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

/// Mutable capture for the synthesis-route reference check.
private final class DanglingReference {
    var first: (String, String, String)?
}
