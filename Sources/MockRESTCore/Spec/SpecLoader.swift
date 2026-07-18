import MockCore

/// Ingests an OpenAPI 3.0.x/3.1.x document into the normalized ``RESTSpec`` model, validating
/// as it goes.
///
/// This is a decoder + validator over the already-parsed value tree, not a character-level
/// parser — every diagnostic carries the document path (`paths./users/{id}.get.responses.200`)
/// and, for near-misses, a "did you mean" suggestion.
struct SpecLoader {
    private let sourceName: String?
    private var spec = RESTSpec()

    private init(sourceName: String?) {
        self.sourceName = sourceName
    }

    /// Loads and validates a spec source.
    static func load(_ source: SpecSource) throws -> RESTSpec {
        var loader = SpecLoader(sourceName: source.sourceName)
        return try loader.run(document: try source.rawDocument())
    }

    private mutating func run(document: MockValue) throws -> RESTSpec {
        guard let root = document.objectValue else {
            throw error("Spec document must be a mapping", at: "")
        }
        if root["swagger"] != nil {
            throw error(
                "Swagger 2.0 documents are not supported; convert the spec to OpenAPI 3 "
                    + "(e.g. with swagger2openapi) first",
                at: "swagger"
            )
        }
        guard let version = root["openapi"]?.stringValue else {
            throw error("Spec document is missing the 'openapi' version field", at: "openapi")
        }
        guard version.hasPrefix("3.0") || version.hasPrefix("3.1") else {
            throw error("Unsupported OpenAPI version '\(version)'; MockREST supports 3.0.x and 3.1.x", at: "openapi")
        }
        if let components = root["components"]?.objectValue, let schemas = components["schemas"]?.objectValue {
            for name in schemas.keys.sorted() {
                guard let value = schemas[name] else { continue }
                let path = "components.schemas.\(name)"
                spec.schemas[name] = try parseNode(value, at: path)
                let fields = value.objectValue ?? [:]
                let (_, typeListNullable) = try parseType(fields["type"], at: path)
                if typeListNullable || fields["nullable"]?.boolValue == true || Self.unionDeclaresNull(fields) {
                    spec.nullableSchemas.insert(name)
                }
                let example = value["example"]
                if !example.isNull {
                    spec.schemaExamples[name] = example
                }
            }
        }
        if let paths = root["paths"]?.objectValue {
            for template in paths.keys.sorted() {
                try parsePathItem(paths[template] ?? .null, template: template)
            }
        }
        try validateReferences()
        return spec
    }

    // MARK: - Schemas

    private mutating func parseNode(_ value: MockValue, at path: String) throws -> SchemaNode {
        guard let fields = value.objectValue else {
            throw error("Schema must be a mapping", at: path)
        }
        if let ref = fields["$ref"] {
            return try parseReference(ref, at: path)
        }
        if let variants = fields["oneOf"] ?? fields["anyOf"] {
            return try parseUnion(variants, at: path)
        }
        if fields["allOf"] != nil {
            throw error("'allOf' is not supported in v1; flatten the schema instead", at: path)
        }
        // Nullability is read at the property level (parseObject); here only the base type
        // matters.
        let (typeName, _) = try parseType(fields["type"], at: path)
        switch typeName {
        case "object":
            return try parseObject(fields, at: path)
        case "array":
            guard let items = fields["items"] else {
                throw error("Array schema is missing 'items'", at: path)
            }
            return .array(of: try parseNode(items, at: "\(path).items"))
        case "string":
            let format = fields["format"]?.stringValue
            var enumValues: [String]?
            if let members = fields["enum"]?.listValue {
                enumValues = members.compactMap(\.stringValue)
            }
            return .string(format: format, enumValues: enumValues)
        case "integer":
            return .integer
        case "number":
            return .number
        case "boolean":
            return .boolean
        case nil:
            return fields["properties"] != nil ? try parseObject(fields, at: path) : .any
        case .some(let other):
            throw error("Unsupported schema type '\(other)'", at: "\(path).type")
        }
    }

    /// Parses `type`, accepting the 3.0 string form and the 3.1 array form (where `"null"`
    /// in the list marks nullability).
    private func parseType(_ value: MockValue?, at path: String) throws -> (String?, nullable: Bool) {
        switch value {
        case nil, .some(.null):
            return (nil, false)
        case .some(.string(let name)):
            return (name, false)
        case .some(.list(let entries)):
            let names = entries.compactMap(\.stringValue)
            guard names.count == entries.count else {
                throw error("'type' array must contain strings", at: "\(path).type")
            }
            let concrete = names.filter { $0 != "null" }
            guard concrete.count == 1 else {
                throw error(
                    "'type' arrays with more than one non-null type are not supported in v1",
                    at: "\(path).type"
                )
            }
            return (concrete[0], names.contains("null"))
        default:
            throw error("'type' must be a string or an array of strings", at: "\(path).type")
        }
    }

    private mutating func parseObject(_ fields: [String: MockValue], at path: String) throws -> SchemaNode {
        var properties: [String: SchemaNode.Property] = [:]
        if let declared = fields["properties"]?.objectValue {
            for name in declared.keys.sorted() {
                guard let value = declared[name], let propertyFields = value.objectValue else {
                    throw error("Property '\(name)' must be a schema mapping", at: "\(path).properties.\(name)")
                }
                let propertyPath = "\(path).properties.\(name)"
                var nullable = propertyFields["nullable"]?.boolValue ?? false
                let (_, typeListNullable) = try parseType(propertyFields["type"], at: propertyPath)
                nullable = nullable || typeListNullable || Self.unionDeclaresNull(propertyFields)
                let node = try parseNode(value, at: propertyPath)
                properties[name] = SchemaNode.Property(node: node, nullable: nullable)
            }
        }
        var required: Set<String> = []
        if let requiredList = fields["required"]?.listValue {
            for entry in requiredList {
                guard let name = entry.stringValue else {
                    throw error("'required' entries must be strings", at: "\(path).required")
                }
                guard properties[name] != nil else {
                    let clause = Suggestion.clause(for: name, in: properties.keys)
                    throw error("'required' names unknown property '\(name)'.\(clause)", at: "\(path).required")
                }
                required.insert(name)
            }
        }
        return .object(properties: properties, required: required)
    }

    private func parseReference(_ value: MockValue, at path: String) throws -> SchemaNode {
        guard let ref = value.stringValue else {
            throw error("'$ref' must be a string", at: "\(path).$ref")
        }
        let prefix = "#/components/schemas/"
        guard ref.hasPrefix(prefix) else {
            throw error(
                "External or non-schema '$ref' '\(ref)' is not supported in v1; "
                    + "only internal '#/components/schemas/…' references are resolved",
                at: "\(path).$ref"
            )
        }
        return .reference(String(ref.dropFirst(prefix.count)))
    }

    private mutating func parseUnion(_ value: MockValue, at path: String) throws -> SchemaNode {
        guard let variants = value.listValue, !variants.isEmpty else {
            throw error("'oneOf'/'anyOf' must be a non-empty list", at: path)
        }
        var names: [String] = []
        for (index, variant) in variants.enumerated() {
            if Self.isNullVariant(variant) {
                continue
            }
            guard case .reference(let name) = try parseNode(variant, at: "\(path)[\(index)]") else {
                throw error(
                    "'oneOf'/'anyOf' variants must be '$ref's to named schemas in v1",
                    at: "\(path)[\(index)]"
                )
            }
            names.append(name)
        }
        guard !names.isEmpty else {
            throw error("'oneOf'/'anyOf' needs at least one non-null variant", at: path)
        }
        return names.count == 1 ? .reference(names[0]) : .oneOf(names)
    }

    /// Whether a schema mapping's `oneOf`/`anyOf` declares a null variant — OpenAPI 3.1's way
    /// of spelling nullability in a union position.
    private static func unionDeclaresNull(_ fields: [String: MockValue]) -> Bool {
        guard let variants = (fields["oneOf"] ?? fields["anyOf"])?.listValue else { return false }
        return variants.contains(where: isNullVariant)
    }

    /// Whether a union variant is `{type: "null"}` (quoted or bare YAML null both occur).
    private static func isNullVariant(_ variant: MockValue) -> Bool {
        guard let type = variant.objectValue?["type"] else { return false }
        return type == .string("null") || type == .null
    }

    // MARK: - Paths

    private mutating func parsePathItem(_ value: MockValue, template: String) throws {
        let basePath = "paths.\(template)"
        guard template.hasPrefix("/") else {
            throw error("Path '\(template)' must start with '/'", at: basePath)
        }
        guard let item = value.objectValue else {
            throw error("Path item must be a mapping", at: basePath)
        }
        let pattern: RoutePattern
        do {
            pattern = try RoutePattern(parsing: template)
        } catch let routeError as MockError {
            throw error(routeError.message, at: basePath)
        }
        let sharedParameters = try parseParameters(item["parameters"], at: "\(basePath).parameters")
        for method in ["get", "post", "put", "patch", "delete"] {
            guard let operation = item[method], !operation.isNull else { continue }
            try parseOperation(
                operation,
                method: method,
                pattern: pattern,
                sharedParameters: sharedParameters,
                at: "\(basePath).\(method)"
            )
        }
    }

    private mutating func parseOperation(
        _ value: MockValue,
        method: String,
        pattern: RoutePattern,
        sharedParameters: [SpecParameter],
        at path: String
    ) throws {
        guard let fields = value.objectValue else {
            throw error("Operation must be a mapping", at: path)
        }
        var parameters = sharedParameters
        parameters.append(contentsOf: try parseParameters(fields["parameters"], at: "\(path).parameters"))

        // Every {param} in the template must be declared as an `in: path` parameter.
        let declaredPathParams = parameters.filter { $0.location == "path" }.map(\.name)
        for name in pattern.parameterNames where !declaredPathParams.contains(name) {
            let clause = Suggestion.clause(for: name, in: declaredPathParams)
            throw error(
                "Path parameter '{\(name)}' is not declared as an 'in: path' parameter.\(clause)",
                at: "\(path).parameters"
            )
        }

        var requestBody: SchemaNode?
        var requestBodyRequired = false
        if let body = fields["requestBody"], !body.isNull {
            if body.objectValue?["$ref"] != nil {
                throw error(
                    "requestBody '$ref's (components.requestBodies) are not supported in v1; "
                        + "inline the body definition",
                    at: "\(path).requestBody"
                )
            }
            requestBody = try parseJSONContentSchema(body, at: "\(path).requestBody")
            requestBodyRequired = body["required"].boolValue ?? false
        }

        var successStatus = 200
        var responseSchema: SchemaNode?
        var responseExample: MockValue?
        if let responses = fields["responses"]?.objectValue {
            // Every response entry is checked — a $ref in a 400 (or a second 2xx) must fail
            // the same way one in the selected success response does.
            for key in responses.keys.sorted() where responses[key]?.objectValue?["$ref"] != nil {
                throw error(
                    "Response '$ref's (components.responses) are not supported in v1; "
                        + "inline the response definition",
                    at: "\(path).responses.\(key)"
                )
            }
            let statuses = responses.keys.compactMap(Int.init).filter { (200..<300).contains($0) }.sorted()
            if let status = statuses.first {
                successStatus = status
                let response = responses[String(status)] ?? .null
                if !response.isNull, response["content"] != nil || response["description"] != nil {
                    responseSchema = try parseOptionalJSONContentSchema(response, at: "\(path).responses.\(status)")
                    responseExample = Self.example(in: response)
                }
            } else if let fallback = responses["default"], !fallback.isNull {
                responseSchema = try parseOptionalJSONContentSchema(fallback, at: "\(path).responses.default")
                responseExample = Self.example(in: fallback)
            }
        }
        spec.operations.append(
            SpecOperation(
                method: method.uppercased(),
                pattern: pattern,
                parameters: parameters,
                requestBody: requestBody,
                requestBodyRequired: requestBodyRequired,
                successStatus: successStatus,
                responseSchema: responseSchema,
                responseExample: responseExample
            )
        )
    }

    private mutating func parseParameters(_ value: MockValue?, at path: String) throws -> [SpecParameter] {
        guard let value, !value.isNull else { return [] }
        guard let entries = value.listValue else {
            throw error("'parameters' must be a list", at: path)
        }
        var parameters: [SpecParameter] = []
        for (index, entry) in entries.enumerated() {
            let entryPath = "\(path)[\(index)]"
            if entry.objectValue?["$ref"] != nil {
                throw error(
                    "Parameter '$ref's (components.parameters) are not supported in v1; "
                        + "inline the parameter definition",
                    at: entryPath
                )
            }
            guard let name = entry["name"].stringValue else {
                throw error("Parameter is missing 'name'", at: entryPath)
            }
            guard let location = entry["in"].stringValue else {
                throw error("Parameter '\(name)' is missing 'in'", at: entryPath)
            }
            guard ["path", "query", "header"].contains(location) else {
                throw error(
                    "Parameter '\(name)' has unsupported location '\(location)' "
                        + "(supported: path, query, header)",
                    at: entryPath
                )
            }
            parameters.append(
                SpecParameter(name: name, location: location, required: entry["required"].boolValue ?? false)
            )
        }
        return parameters
    }

    /// Extracts the `content.application/json.schema` of a request body or response.
    private mutating func parseJSONContentSchema(_ value: MockValue, at path: String) throws -> SchemaNode {
        guard let node = try parseOptionalJSONContentSchema(value, at: path) else {
            let types = value["content"].objectValue?.keys.sorted().joined(separator: ", ") ?? "none"
            throw error(
                "Only 'application/json' content is supported in v1 (declared: \(types))",
                at: "\(path).content"
            )
        }
        return node
    }

    private mutating func parseOptionalJSONContentSchema(_ value: MockValue, at path: String) throws -> SchemaNode? {
        guard let content = value["content"].objectValue, let json = content["application/json"] else {
            return nil
        }
        let schema = json["schema"]
        guard !schema.isNull else { return nil }
        return try parseNode(schema, at: "\(path).content.application/json.schema")
    }

    /// The example attached to a response's JSON content, when present.
    private static func example(in response: MockValue) -> MockValue? {
        let json = response["content"]["application/json"]
        let direct = json["example"]
        if !direct.isNull {
            return direct
        }
        // `examples` is a named map; take the first by sorted key for determinism.
        if let named = json["examples"].objectValue, let first = named.keys.sorted().first {
            let value = named[first]?["value"] ?? .null
            return value.isNull ? nil : value
        }
        return nil
    }

    // MARK: - Cross-validation

    /// Verifies every `$ref`/union target names a real schema, and that pure alias chains
    /// (a named schema that is itself just a `$ref`) terminate — a cycle would recurse forever
    /// during coercion.
    private func validateReferences() throws {
        func check(_ node: SchemaNode, at path: String) throws {
            switch node {
            case .reference(let name):
                guard spec.schemas[name] != nil else {
                    let clause = Suggestion.clause(for: name, in: spec.schemas.keys)
                    throw error("Unknown schema '\(name)' referenced.\(clause)", at: path)
                }
            case .oneOf(let names):
                for name in names where spec.schemas[name] == nil {
                    let clause = Suggestion.clause(for: name, in: spec.schemas.keys)
                    throw error("Unknown schema '\(name)' referenced.\(clause)", at: path)
                }
            case .array(let element):
                try check(element, at: path)
            case .object(let properties, _):
                for (name, property) in properties.sorted(by: { $0.key < $1.key }) {
                    try check(property.node, at: "\(path).\(name)")
                }
            default:
                break
            }
        }

        for name in spec.schemas.keys.sorted() {
            try check(spec.schemas[name] ?? .any, at: "components.schemas.\(name)")
            var chain: Set<String> = [name]
            var current = name
            while case .reference(let next) = spec.schemas[current] ?? .any {
                guard chain.insert(next).inserted else {
                    throw error(
                        "Circular '$ref' chain detected while resolving '\(name)': "
                            + "'\(next)' is reached twice",
                        at: "components.schemas.\(name)"
                    )
                }
                current = next
            }
        }
        for operation in spec.operations {
            let base = "paths.\(operation.pattern.template).\(operation.method.lowercased())"
            if let body = operation.requestBody {
                try check(body, at: "\(base).requestBody")
            }
            if let response = operation.responseSchema {
                try check(response, at: "\(base).responses.\(operation.successStatus)")
            }
        }
    }

    // MARK: - Helpers

    private func error(_ message: String, at path: String) -> MockError {
        MockError(
            category: .schema,
            message: message,
            sourceName: sourceName,
            documentPath: path.isEmpty ? nil : path
        )
    }
}
