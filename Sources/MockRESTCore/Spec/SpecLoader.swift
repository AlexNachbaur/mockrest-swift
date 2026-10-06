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
    /// The raw `components` mapping, for resolving `$ref`s to parameters, request bodies, and
    /// responses.
    private var components: [String: MockValue] = [:]

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
        components = root["components"]?.objectValue ?? [:]
        if let schemas = components["schemas"]?.objectValue {
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
        // Keys beyond `properties`. OpenAPI's default is "anything goes", but MockREST keeps
        // objects that declare properties closed unless the spec opts in — that strictness is
        // what turns a seed or request typo into a "did you mean" diagnostic. An object with
        // no declared properties at all is free-form: there is nothing to typo against.
        var additional: SchemaNode?
        switch fields["additionalProperties"] {
        case nil, .some(.null):
            additional = fields["properties"] == nil ? .any : nil
        case .some(.bool(let allowed)):
            additional = allowed ? .any : nil
        case .some(let schema):
            additional = try parseNode(schema, at: "\(path).additionalProperties")
        }
        var required: Set<String> = []
        if let requiredList = fields["required"]?.listValue {
            for entry in requiredList {
                guard let name = entry.stringValue else {
                    throw error("'required' entries must be strings", at: "\(path).required")
                }
                // On an open object a required key need not be a declared property; on a closed
                // one it could never be supplied, so it is a typo.
                guard properties[name] != nil || additional != nil else {
                    let clause = Suggestion.clause(for: name, in: properties.keys)
                    throw error("'required' names unknown property '\(name)'.\(clause)", at: "\(path).required")
                }
                required.insert(name)
            }
        }
        return .object(properties: properties, required: required, additional: additional)
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
        if let declared = fields["requestBody"], !declared.isNull {
            let (body, bodyPath) = try resolveComponent(
                declared, section: "requestBodies", at: "\(path).requestBody")
            requestBody = try parseJSONContentSchema(body, at: bodyPath)
            requestBodyRequired = body["required"].boolValue ?? false
        }

        var successStatus = 200
        var responseSchema: SchemaNode?
        var responseExample: MockValue?
        if let responses = fields["responses"]?.objectValue {
            // Every response entry is resolved — a broken $ref in a 400 (or a second 2xx) must
            // fail the same way one in the selected success response does.
            var resolved: [String: (value: MockValue, path: String)] = [:]
            for key in responses.keys.sorted() {
                guard let declared = responses[key], !declared.isNull else { continue }
                resolved[key] = try resolveComponent(
                    declared, section: "responses", at: "\(path).responses.\(key)")
            }
            let statuses = responses.keys.compactMap(Int.init).filter { (200..<300).contains($0) }.sorted()
            if let status = statuses.first {
                successStatus = status
                if let (response, responsePath) = resolved[String(status)],
                    response["content"] != nil || response["description"] != nil
                {
                    responseSchema = try parseOptionalJSONContentSchema(response, at: responsePath)
                    responseExample = Self.example(in: response)
                }
            } else if let (fallback, fallbackPath) = resolved["default"] {
                responseSchema = try parseOptionalJSONContentSchema(fallback, at: fallbackPath)
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
        for (index, declared) in entries.enumerated() {
            let (entry, entryPath) = try resolveComponent(
                declared, section: "parameters", at: "\(path)[\(index)]")
            guard let name = entry["name"].stringValue else {
                throw error("Parameter is missing 'name'", at: entryPath)
            }
            guard let location = entry["in"].stringValue else {
                throw error("Parameter '\(name)' is missing 'in'", at: entryPath)
            }
            guard ["path", "query", "header", "cookie"].contains(location) else {
                let clause = Suggestion.clause(for: location, in: ["path", "query", "header", "cookie"])
                throw error(
                    "Parameter '\(name)' has unsupported location '\(location)' "
                        + "(supported: path, query, header, cookie).\(clause)",
                    at: entryPath
                )
            }
            // Cookie parameters are accepted so real-world specs load, and otherwise ignored:
            // UI tests rarely manage a cookie jar against a mock, so nothing is enforced.
            if location == "cookie" {
                continue
            }
            parameters.append(
                SpecParameter(name: name, location: location, required: entry["required"].boolValue ?? false)
            )
        }
        return parameters
    }

    /// Follows a `$ref` into `components.<section>` (parameters, requestBodies, responses) and
    /// returns the definition it names, with the document path diagnostics inside it should
    /// carry. A value that is not a `$ref` is returned unchanged.
    private func resolveComponent(
        _ value: MockValue,
        section: String,
        at path: String
    ) throws -> (value: MockValue, path: String) {
        var current = value
        var currentPath = path
        var visited: Set<String> = []
        while let ref = current.objectValue?["$ref"] {
            guard let target = ref.stringValue else {
                throw error("'$ref' must be a string", at: "\(currentPath).$ref")
            }
            let prefix = "#/components/\(section)/"
            guard target.hasPrefix(prefix) else {
                throw error(
                    "External or mismatched '$ref' '\(target)' is not supported in v1; "
                        + "only internal '\(prefix)…' references are resolved here",
                    at: "\(currentPath).$ref"
                )
            }
            let name = String(target.dropFirst(prefix.count))
            let available = components[section]?.objectValue ?? [:]
            guard let definition = available[name], !definition.isNull else {
                let clause = Suggestion.clause(for: name, in: available.keys)
                throw error(
                    "Unknown component '\(name)' referenced in 'components.\(section)'.\(clause)",
                    at: "\(currentPath).$ref"
                )
            }
            guard visited.insert(name).inserted else {
                throw error(
                    "Circular '$ref' chain detected while resolving '\(target)': "
                        + "'\(name)' is reached twice",
                    at: "\(currentPath).$ref"
                )
            }
            current = definition
            currentPath = "components.\(section).\(name)"
        }
        return (current, currentPath)
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
            case .object(let properties, _, let additional):
                for (name, property) in properties.sorted(by: { $0.key < $1.key }) {
                    try check(property.node, at: "\(path).\(name)")
                }
                if let additional {
                    try check(additional, at: "\(path).additionalProperties")
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
