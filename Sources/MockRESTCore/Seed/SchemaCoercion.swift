import MockCore

/// Validates and coerces authored values (seed records, request bodies) against the spec's
/// schemas — one implementation so seeds and requests reject the same inputs with the same
/// diagnostics.
///
/// Reference semantics are schema-driven, mirroring MockQL: a string (or int) in a position
/// whose schema is another **object** schema is a reference to that record's id; a string in a
/// scalar position is a literal; a nested map is an anonymous embedded value object; union
/// (`oneOf`) positions need qualified `Schema:id` strings so the concrete type is known.
struct SchemaCoercion {
    let spec: RESTSpec
    let category: MockError.Category
    let sourceName: String?
    /// Called for every reference encountered so the caller can validate it (immediately for
    /// requests, after the whole document loads for seeds).
    let recordReference: (_ typeName: String, _ id: String, _ path: String) -> Void

    /// Validates a record's fields against a named object schema and returns the coerced
    /// fields.
    ///
    /// - Parameters:
    ///   - requireRequired: Enforce the schema's `required` list (request bodies for POST/PUT).
    ///     Seeds and PATCH bodies skip it — omitted fields are generated or left unchanged.
    ///   - skipRequiredFields: Field names exempt from the `required` check (the id field of a
    ///     create, which the server generates).
    func coerceRecord(
        _ fields: [String: MockValue],
        schemaName: String,
        at path: String,
        idField: String? = nil,
        requireRequired: Bool = false,
        skipRequiredFields: Set<String> = []
    ) throws -> [String: MockValue] {
        guard case .object(let properties, let required) = spec.schemas[schemaName] else {
            throw error("'\(schemaName)' is not an object schema", at: path)
        }
        var coerced: [String: MockValue] = [:]
        for name in fields.keys.sorted() {
            guard let property = properties[name] else {
                let clause = Suggestion.clause(for: name, in: properties.keys)
                throw error("Unknown field '\(name)' on '\(schemaName)'.\(clause)", at: "\(path).\(name)")
            }
            guard var value = fields[name] else { continue }
            // Integer ids coerce to string ids (as in MockQL) when the id field is string-typed.
            if name == idField, case .int(let number) = value, case .string = property.node {
                value = .string(String(number))
            }
            coerced[name] = try coerce(value, to: property, at: "\(path).\(name)")
        }
        if requireRequired {
            for name in required.sorted() where coerced[name] == nil && !skipRequiredFields.contains(name) {
                throw error("Missing required field '\(name)' of '\(schemaName)'", at: path)
            }
        }
        return coerced
    }

    /// Coerces a request body against an operation's declared schema, enforcing the object's
    /// `required` list (directly or through a `$ref` to an object schema) the way CRUD
    /// validation does.
    func coerceBody(_ value: MockValue, to node: SchemaNode, at path: String) throws -> MockValue {
        switch node {
        case .reference(var name):
            // Follow alias chains (A -> B -> Object) to the terminal schema; cycles were
            // rejected at load, so this terminates. Required enforcement must not depend on
            // how many alias hops the spec author used.
            while case .reference(let next) = spec.schemas[name] ?? .any {
                name = next
            }
            if case .object = spec.schemas[name] ?? .any, let fields = value.objectValue {
                return .object(try coerceRecord(fields, schemaName: name, at: path, requireRequired: true))
            }
            return try coerce(value, to: node, at: path)
        case .object(let properties, let required):
            guard let fields = value.objectValue else {
                throw error("Expected an object, found \(value)", at: path)
            }
            var coerced: [String: MockValue] = [:]
            for name in fields.keys.sorted() {
                guard let property = properties[name] else {
                    let clause = Suggestion.clause(for: name, in: properties.keys)
                    throw error("Unknown field '\(name)'.\(clause)", at: "\(path).\(name)")
                }
                guard let fieldValue = fields[name] else { continue }
                coerced[name] = try coerce(fieldValue, to: property, at: "\(path).\(name)")
            }
            for name in required.sorted() where coerced[name] == nil {
                throw error("Missing required field '\(name)'", at: path)
            }
            return .object(coerced)
        default:
            return try coerce(value, to: node, at: path)
        }
    }

    /// Coerces a value into a property position, handling explicit nulls.
    func coerce(_ value: MockValue, to property: SchemaNode.Property, at path: String) throws -> MockValue {
        if value.isNull {
            if property.nullable {
                return .null
            }
            // A `$ref` chain to a nullable schema also accepts null — nullability at any hop
            // (A -> B where either A or B is nullable) makes the position nullable. Cycles are
            // rejected at load, so the walk terminates.
            if case .reference(var name) = property.node {
                while true {
                    if spec.nullableSchemas.contains(name) {
                        return .null
                    }
                    guard case .reference(let next) = spec.schemas[name] ?? .any else { break }
                    name = next
                }
            }
            throw error("Explicit null is not allowed here (the schema is not nullable)", at: path)
        }
        return try coerce(value, to: property.node, at: path)
    }

    /// Coerces a value into a schema position.
    func coerce(_ value: MockValue, to node: SchemaNode, at path: String) throws -> MockValue {
        switch node {
        case .any:
            return value
        case .string(_, let enumValues):
            if let enumValues {
                let name = value.stringValue ?? value.enumName
                guard let name, enumValues.contains(name) else {
                    let described = value.stringValue ?? value.enumName ?? value.description
                    let clause = Suggestion.clause(for: described, in: enumValues)
                    throw error(
                        "'\(described)' is not one of \(enumValues.joined(separator: ", ")).\(clause)",
                        at: path
                    )
                }
                return .enumValue(name)
            }
            guard let text = value.stringValue else {
                var hint = ""
                if value.intValue != nil || value.boolValue != nil {
                    hint = " (quote the value to make it a string)"
                }
                throw error("Expected a string, found \(value)\(hint)", at: path)
            }
            return .string(text)
        case .integer:
            guard value.intValue != nil else {
                throw error("Expected an integer, found \(value)", at: path)
            }
            return value
        case .number:
            if let int = value.intValue {
                return .double(Double(int))
            }
            guard case .double = value else {
                throw error("Expected a number, found \(value)", at: path)
            }
            return value
        case .boolean:
            guard value.boolValue != nil else {
                throw error("Expected a boolean, found \(value)", at: path)
            }
            return value
        case .array(let element):
            guard let items = value.listValue else {
                throw error("Expected an array, found \(value)", at: path)
            }
            return .list(
                try items.enumerated().map { index, item in
                    try coerce(item, to: element, at: "\(path)[\(index)]")
                }
            )
        case .object(let properties, _):
            guard let fields = value.objectValue else {
                throw error("Expected an object, found \(value)", at: path)
            }
            var coerced: [String: MockValue] = [:]
            for name in fields.keys.sorted() {
                guard let property = properties[name] else {
                    let clause = Suggestion.clause(for: name, in: properties.keys)
                    throw error("Unknown field '\(name)'.\(clause)", at: "\(path).\(name)")
                }
                guard let fieldValue = fields[name] else { continue }
                coerced[name] = try coerce(fieldValue, to: property, at: "\(path).\(name)")
            }
            return .object(coerced)
        case .reference(let target):
            return try coerceReferencePosition(value, target: target, at: path)
        case .oneOf(let names):
            return try coerceUnionPosition(value, names: names, at: path)
        }
    }

    private func coerceReferencePosition(_ value: MockValue, target: String, at path: String) throws -> MockValue {
        guard case .object = spec.schemas[target] else {
            // The $ref names a scalar alias — coerce against the aliased shape directly.
            guard let aliased = spec.schemas[target] else {
                throw error("Internal error: unknown schema '\(target)'", at: path)
            }
            return try coerce(value, to: aliased, at: path)
        }
        switch value {
        case .string(let text):
            if let qualified = parseQualifiedReference(text) {
                guard qualified.typeName == target else {
                    throw error(
                        "Reference '\(text)' points at '\(qualified.typeName)', but this position holds "
                            + "'\(target)'",
                        at: path
                    )
                }
                recordReference(qualified.typeName, qualified.id, path)
                return .reference(qualified.typeName, id: qualified.id)
            }
            recordReference(target, text, path)
            return .reference(target, id: text)
        case .int(let id):
            recordReference(target, String(id), path)
            return .reference(target, id: String(id))
        case .reference(let typeName, let id):
            guard typeName == target else {
                throw error("Reference points at '\(typeName)', but this position holds '\(target)'", at: path)
            }
            recordReference(typeName, id, path)
            return value
        case .object(let fields):
            // An anonymous embedded value object, validated against the target schema.
            return .object(try coerceRecord(fields, schemaName: target, at: path))
        default:
            throw error("Expected a reference or object for '\(target)', found \(value)", at: path)
        }
    }

    private func coerceUnionPosition(_ value: MockValue, names: [String], at path: String) throws -> MockValue {
        let possible = names.joined(separator: ", ")
        switch value {
        case .string(let text):
            guard let qualified = parseQualifiedReference(text) else {
                throw error(
                    "This position holds one of \(possible); use a qualified reference like "
                        + "'\(names.first ?? "Schema"):\(text)' so the concrete schema is known",
                    at: path
                )
            }
            guard names.contains(qualified.typeName) else {
                throw error(
                    "'\(qualified.typeName)' is not one of the possible schemas here "
                        + "(expected one of: \(possible))",
                    at: path
                )
            }
            recordReference(qualified.typeName, qualified.id, path)
            return .reference(qualified.typeName, id: qualified.id)
        case .reference(let typeName, let id):
            guard names.contains(typeName) else {
                throw error(
                    "'\(typeName)' is not one of the possible schemas here (expected one of: \(possible))",
                    at: path
                )
            }
            recordReference(typeName, id, path)
            return value
        case .object:
            throw error(
                "Embedded objects cannot be used in a oneOf/anyOf position; use a qualified "
                    + "reference like 'Schema:id'",
                at: path
            )
        default:
            throw error("Expected a qualified reference here, found \(value)", at: path)
        }
    }

    /// A string is a qualified reference when the text before the first ':' names an object
    /// schema.
    private func parseQualifiedReference(_ text: String) -> (typeName: String, id: String)? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let prefix = String(text[..<colon])
        let id = String(text[text.index(after: colon)...])
        guard !id.isEmpty, case .object = spec.schemas[prefix] else { return nil }
        return (prefix, id)
    }

    func error(_ message: String, at path: String) -> MockError {
        MockError(
            category: category,
            message: message,
            sourceName: sourceName,
            documentPath: path.isEmpty ? nil : path
        )
    }
}
