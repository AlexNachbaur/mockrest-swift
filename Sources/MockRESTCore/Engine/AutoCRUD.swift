import MockCore

/// Builds the conventional CRUD handlers for a resource collection, all overridable by a DSL
/// endpoint on the same method + path.
struct AutoCRUD {
    let resource: ResourceModel
    let spec: RESTSpec?
    let synthesizer: ResponseSynthesizer

    /// Query parameter names with engine-defined meaning on list endpoints; everything else is
    /// an equality filter.
    private static let reservedQueryParams: Set<String> = ["limit", "offset", "sort"]

    /// The routes this resource contributes: list/create on the base path, get/replace/merge/
    /// delete on `{base}/{id}`.
    func routes() throws -> [EngineRoute] {
        let collection = try RoutePattern(parsing: resource.basePath)
        let item = try RoutePattern(parsing: "\(resource.basePath)/{\(resource.itemParamName)}")
        return [
            EngineRoute(method: "GET", pattern: collection, handler: list()),
            EngineRoute(method: "POST", pattern: collection, handler: create()),
            EngineRoute(method: "GET", pattern: item, handler: getOne()),
            EngineRoute(method: "PUT", pattern: item, handler: replace()),
            EngineRoute(method: "PATCH", pattern: item, handler: merge()),
            EngineRoute(method: "DELETE", pattern: item, handler: delete()),
        ]
    }

    // MARK: - Handlers

    private func list() -> RESTHandler {
        let resource = resource
        let spec = spec
        let synthesizer = synthesizer
        return { request, state in
            var records = state.records(ofType: resource.schema)

            // ?field=value filters by equality on the stored value.
            for (name, value) in request.query where !Self.reservedQueryParams.contains(name) {
                records = records.filter { Self.fieldMatches($0[name], query: value) }
            }
            // ?sort=field ascending, ?sort=-field descending.
            if let sort = request.queryValue("sort"), !sort.isEmpty {
                let descending = sort.hasPrefix("-")
                let field = descending ? String(sort.dropFirst()) : sort
                records.sort {
                    descending ? Self.ascending($1[field], $0[field]) : Self.ascending($0[field], $1[field])
                }
            }
            let total = records.count
            var offset = 0
            var limit: Int?
            if let rawOffset = request.queryValue("offset") {
                guard let parsed = Int(rawOffset), parsed >= 0 else {
                    return .errors(status: 400, [(message: "'offset' must be a non-negative integer", path: nil)])
                }
                offset = parsed
            }
            if let rawLimit = request.queryValue("limit") {
                guard let parsed = Int(rawLimit), parsed >= 0 else {
                    return .errors(status: 400, [(message: "'limit' must be a non-negative integer", path: nil)])
                }
                limit = parsed
            }
            if offset > 0 {
                records = Array(records.dropFirst(offset))
            }
            if let limit {
                records = Array(records.prefix(limit))
            }
            let data = state.storeData
            let serialized = records.map {
                Self.present(
                    synthesizer.serializeRecord($0, schemaName: resource.schema, data: data),
                    resource: resource,
                    spec: spec
                )
            }
            guard let envelope = resource.listEnvelope else {
                return .ok(.list(serialized))
            }
            // Synthesize the spec's envelope shape around the page.
            var body: [String: MockValue] = [envelope.itemsProperty: .list(serialized)]
            for (name, property) in envelope.extraProperties {
                switch name.lowercased() {
                case "total", "count", "totalcount":
                    body[name] = .int(total)
                case "limit", "pagesize", "per_page", "perpage":
                    body[name] = .int(limit ?? serialized.count)
                case "offset":
                    body[name] = .int(offset)
                case "page":
                    body[name] = .int((limit.map { $0 > 0 ? offset / $0 : 0 } ?? 0) + 1)
                default:
                    body[name] = synthesizer.synthesize(
                        node: property.node,
                        pseudoType: resource.schema,
                        fieldName: name,
                        data: data
                    )
                }
            }
            return .ok(.object(body))
        }
    }

    private func getOne() -> RESTHandler {
        let resource = resource
        let spec = spec
        let synthesizer = synthesizer
        return { request, state in
            let id = request.pathParam(resource.itemParamName)
            let record = state[resource.schema, id: id]
            guard !record.isNull else {
                return Self.missing(resource: resource, id: id, state: state)
            }
            let body = synthesizer.serializeRecord(record, schemaName: resource.schema, data: state.storeData)
            return .ok(Self.present(body, resource: resource, spec: spec))
        }
    }

    private func create() -> RESTHandler {
        let resource = resource
        let spec = spec
        let synthesizer = synthesizer
        return { request, state in
            guard var fields = request.body.objectValue else {
                return .errors(status: 422, [(message: "Request body must be a JSON object", path: "body")])
            }
            if spec != nil {
                switch Self.validate(
                    fields, resource: resource, spec: spec, state: state, requireRequired: true)
                {
                case .success(let coerced): fields = coerced
                case .failure(let response): return response
                }
            }
            // Provided ids win (409 on conflict); otherwise the store generates one.
            let id: String
            if let provided = fields[resource.idField]?.stringValue
                ?? fields[resource.idField]?.intValue.map(
                    String.init)
            {
                guard state[resource.schema, id: provided].isNull else {
                    return .errors(
                        status: 409,
                        [(message: "A '\(resource.schema)' with id '\(provided)' already exists", path: nil)]
                    )
                }
                id = provided
                fields["id"] = .string(id)
                fields[resource.idField] = .string(id)
                state[resource.schema, id: id] = .object(fields)
            } else {
                let inserted = state.insert(resource.schema, .object(fields))
                id = inserted["id"].stringValue ?? ""
                if resource.idField != "id" {
                    state.update(resource.schema, id: id) { $0[resource.idField] = .string(id) }
                }
            }
            let record = state[resource.schema, id: id]
            let body = synthesizer.serializeRecord(record, schemaName: resource.schema, data: state.storeData)
            return .created(Self.present(body, resource: resource, spec: spec), location: "\(resource.basePath)/\(id)")
        }
    }

    private func replace() -> RESTHandler {
        let resource = resource
        let spec = spec
        let synthesizer = synthesizer
        return { request, state in
            let id = request.pathParam(resource.itemParamName)
            guard !state[resource.schema, id: id].isNull else {
                return Self.missing(resource: resource, id: id, state: state)
            }
            guard var fields = request.body.objectValue else {
                return .errors(status: 422, [(message: "Request body must be a JSON object", path: "body")])
            }
            if spec != nil {
                switch Self.validate(
                    fields, resource: resource, spec: spec, state: state, requireRequired: true)
                {
                case .success(let coerced): fields = coerced
                case .failure(let response): return response
                }
            }
            fields["id"] = .string(id)
            fields[resource.idField] = .string(id)
            state[resource.schema, id: id] = .object(fields)
            let body = synthesizer.serializeRecord(
                state[resource.schema, id: id], schemaName: resource.schema, data: state.storeData)
            return .ok(Self.present(body, resource: resource, spec: spec))
        }
    }

    private func merge() -> RESTHandler {
        let resource = resource
        let spec = spec
        let synthesizer = synthesizer
        return { request, state in
            let id = request.pathParam(resource.itemParamName)
            guard !state[resource.schema, id: id].isNull else {
                return Self.missing(resource: resource, id: id, state: state)
            }
            guard var fields = request.body.objectValue else {
                return .errors(status: 422, [(message: "Request body must be a JSON object", path: "body")])
            }
            if spec != nil {
                switch Self.validate(
                    fields, resource: resource, spec: spec, state: state, requireRequired: false)
                {
                case .success(let coerced): fields = coerced
                case .failure(let response): return response
                }
            }
            fields["id"] = nil
            fields[resource.idField] = nil
            state.update(resource.schema, id: id) { record in
                for (name, value) in fields {
                    record[name] = value
                }
            }
            let body = synthesizer.serializeRecord(
                state[resource.schema, id: id], schemaName: resource.schema, data: state.storeData)
            return .ok(Self.present(body, resource: resource, spec: spec))
        }
    }

    private func delete() -> RESTHandler {
        let resource = resource
        return { request, state in
            state.delete(resource.schema, id: request.pathParam(resource.itemParamName))
            return .noContent
        }
    }

    // MARK: - Shared pieces

    /// The outcome of request-body validation: coerced fields, or the 422 to send back.
    private enum ValidationOutcome {
        case success([String: MockValue])
        case failure(RESTResponse)
    }

    /// Validates request-body fields against the resource's schema, checking references
    /// against current state immediately. Returns the coerced fields or a 422.
    private static func validate(
        _ fields: [String: MockValue],
        resource: ResourceModel,
        spec: RESTSpec?,
        state: MutationState,
        requireRequired: Bool
    ) -> ValidationOutcome {
        guard let spec else { return .success(fields) }
        let dangling = DanglingBox()
        let coercion = SchemaCoercion(
            spec: spec,
            category: .seed,
            sourceName: nil,
            recordReference: { typeName, id, path in
                if state[typeName, id: id].isNull {
                    dangling.first = dangling.first ?? (typeName, id, path)
                }
            }
        )
        do {
            let coerced = try coercion.coerceRecord(
                fields,
                schemaName: resource.schema,
                at: "body",
                idField: resource.idField,
                requireRequired: requireRequired,
                skipRequiredFields: [resource.idField]
            )
            if let (typeName, id, path) = dangling.first {
                return .failure(
                    .errors(
                        status: 422,
                        [(message: "No '\(typeName)' record with id '\(id)'", path: path)]
                    )
                )
            }
            return .success(coerced)
        } catch let error as MockError {
            return .failure(.errors(status: 422, [(message: error.message, path: error.documentPath)]))
        } catch {
            return .failure(.errors(status: 422, [(message: String(describing: error), path: nil)]))
        }
    }

    /// Mutable capture for the reference-check closure.
    private final class DanglingBox {
        var first: (String, String, String)?
    }

    /// In DSL-only mode with a custom id field, the canonical internal `id` the store keeps
    /// would leak mock internals into responses — strip it.
    private static func present(_ body: MockValue, resource: ResourceModel, spec: RESTSpec?) -> MockValue {
        guard spec == nil, resource.idField != "id", var fields = body.objectValue else { return body }
        fields["id"] = nil
        return .object(fields)
    }

    /// A 404 whose message names near-miss ids — diagnosable from the response alone.
    private static func missing(resource: ResourceModel, id: String, state: MutationState) -> RESTResponse {
        let known = state.ids(ofType: resource.schema)
        let clause = Suggestion.clause(for: id, in: known)
        return .notFound("No '\(resource.schema)' with id '\(id)'.\(clause)")
    }

    private static func fieldMatches(_ value: MockValue, query: String) -> Bool {
        switch value {
        case .string(let text): return text == query
        case .enumValue(let name): return name == query
        case .int(let number): return Int(query) == number
        case .double(let number): return Double(query) == number
        case .bool(let flag): return Bool(query) == flag
        case .reference(_, let id): return id == query
        default: return false
        }
    }

    private static func ascending(_ lhs: MockValue, _ rhs: MockValue) -> Bool {
        switch (lhs, rhs) {
        case (.int(let left), .int(let right)): return left < right
        case (.double(let left), .double(let right)): return left < right
        case (.int(let left), .double(let right)): return Double(left) < right
        case (.double(let left), .int(let right)): return left < Double(right)
        case (.string(let left), .string(let right)): return left < right
        case (.enumValue(let left), .enumValue(let right)): return left < right
        case (.null, _): return false
        case (_, .null): return true
        default: return lhs.description < rhs.description
        }
    }

}

/// One matched route in the engine's table.
struct EngineRoute: Sendable {
    var method: String
    var pattern: RoutePattern
    var handler: RESTHandler
}
