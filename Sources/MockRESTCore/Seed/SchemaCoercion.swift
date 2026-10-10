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
    ///   - requireRequired: Enforce the schema's `required` list, here and in every object
    ///     nested inside the record (request bodies for POST/PUT). Seeds and PATCH bodies skip
    ///     it — omitted fields are generated or left unchanged.
    ///   - skipRequiredFields: Top-level field names exempt from the `required` check (the id
    ///     field of a create, which the server generates).
    func coerceRecord(
        _ fields: [String: MockValue],
        schemaName: String,
        at path: String,
        idField: String? = nil,
        requireRequired: Bool = false,
        skipRequiredFields: Set<String> = []
    ) throws -> [String: MockValue] {
        guard case .object(let properties, let required, let additional) = spec.schemas[schemaName] else {
            throw error("'\(schemaName)' is not an object schema", at: path)
        }
        var fields = fields
        // Integer ids coerce to string ids (as in MockQL) when the id field is string-typed.
        if let idField, case .some(.int(let number)) = fields[idField],
            case .some(.string) = properties[idField]?.node
        {
            fields[idField] = .string(String(number))
        }
        return try coerceFields(
            fields,
            shape: ObjectShape(properties: properties, required: required, additional: additional),
            owner: schemaName,
            at: path,
            requireRequired: requireRequired,
            skipRequiredFields: skipRequiredFields
        )
    }

    /// The parts of an object schema field coercion works from.
    private struct ObjectShape {
        var properties: [String: SchemaNode.Property]
        var required: Set<String>
        var additional: SchemaNode?
    }

    /// The one place object fields are checked: declared properties coerce against their
    /// schema, other keys against `additionalProperties` (or are rejected with a suggestion
    /// when the object is closed), and `required` is enforced when asked.
    private func coerceFields(
        _ fields: [String: MockValue],
        shape: ObjectShape,
        owner: String?,
        at path: String,
        requireRequired: Bool,
        skipRequiredFields: Set<String> = []
    ) throws -> [String: MockValue] {
        var coerced: [String: MockValue] = [:]
        for name in fields.keys.sorted() {
            guard let value = fields[name] else { continue }
            let fieldPath = "\(path).\(name)"
            if let property = shape.properties[name] {
                coerced[name] = try coerce(value, to: property, at: fieldPath, requireRequired: requireRequired)
            } else if let additional = shape.additional {
                // Extra keys on an open object coerce against the `additionalProperties`
                // schema. A typed one does not admit `null` any more than a declared property
                // would (`.any` admits everything, nulls included).
                coerced[name] = try coerce(
                    value,
                    to: SchemaNode.Property(node: additional, nullable: additional == .any),
                    at: fieldPath,
                    requireRequired: requireRequired
                )
            } else {
                let clause = Suggestion.clause(for: name, in: shape.properties.keys)
                let suffix = owner.map { " on '\($0)'" } ?? ""
                throw error("Unknown field '\(name)'\(suffix).\(clause)", at: fieldPath)
            }
        }
        if requireRequired {
            // A `readOnly` property is the server's to fill, so a request may leave it out even
            // when it is `required` — that combination is how generated specs describe ids and
            // timestamps, and rejecting it would refuse every real-world create.
            for name in shape.required.sorted()
            where coerced[name] == nil && !skipRequiredFields.contains(name)
                && shape.properties[name]?.readOnly != true
            {
                let suffix = owner.map { " of '\($0)'" } ?? ""
                throw error("Missing required field '\(name)'\(suffix)", at: path)
            }
        }
        return coerced
    }

    /// Coerces a request body against an operation's declared schema, enforcing `required`
    /// lists throughout (directly or through a `$ref` to an object schema) the way CRUD
    /// validation does.
    func coerceBody(_ value: MockValue, to node: SchemaNode, at path: String) throws -> MockValue {
        // Follow alias chains (A -> B -> Object) to the terminal schema; cycles were rejected
        // at load, so this terminates. Required enforcement must not depend on how many alias
        // hops the spec author used.
        if case .reference(let name) = node, let target = spec.aliasTarget(of: name), case .object = target.node {
            // A body is the object itself, never a reference to a stored record.
            guard let fields = value.objectValue else {
                throw error("Expected an object, found \(value)", at: path)
            }
            return .object(try coerceRecord(fields, schemaName: target.name, at: path, requireRequired: true))
        }
        return try coerce(value, to: node, at: path, requireRequired: true)
    }

    /// Coerces a value into a property position, handling explicit nulls.
    func coerce(
        _ value: MockValue,
        to property: SchemaNode.Property,
        at path: String,
        requireRequired: Bool = false
    ) throws -> MockValue {
        if value.isNull {
            if property.nullable || acceptsNullThroughIndirection(property.node) {
                return .null
            }
            throw error("Explicit null is not allowed here (the schema is not nullable)", at: path)
        }
        return try coerce(value, to: property.node, at: path, requireRequired: requireRequired)
    }

    /// Whether a position accepts null through indirection: a `$ref` chain with a nullable hop,
    /// or a union any of whose variants' chains is nullable. Cycles are rejected at load, so
    /// the walks terminate.
    private func acceptsNullThroughIndirection(_ node: SchemaNode) -> Bool {
        switch node {
        case .reference(let name):
            return aliasChainIsNullable(startingAt: name)
        case .oneOf(let names):
            return names.contains { aliasChainIsNullable(startingAt: $0) }
        default:
            return false
        }
    }

    private func aliasChainIsNullable(startingAt name: String) -> Bool {
        var current = name
        while true {
            if spec.nullableSchemas.contains(current) {
                return true
            }
            guard case .reference(let next) = spec.schemas[current] ?? .any else { return false }
            current = next
        }
    }

    /// Coerces a value into a schema position. `requireRequired` enforces `required` lists on
    /// every object reached from here.
    func coerce(
        _ value: MockValue,
        to node: SchemaNode,
        at path: String,
        requireRequired: Bool = false
    ) throws -> MockValue {
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
                    try coerce(item, to: element, at: "\(path)[\(index)]", requireRequired: requireRequired)
                }
            )
        case .object(let properties, let required, let additional):
            guard let fields = value.objectValue else {
                throw error("Expected an object, found \(value)", at: path)
            }
            return .object(
                try coerceFields(
                    fields,
                    shape: ObjectShape(properties: properties, required: required, additional: additional),
                    owner: nil,
                    at: path,
                    requireRequired: requireRequired
                )
            )
        case .reference(let target):
            return try coerceReferencePosition(value, target: target, at: path, requireRequired: requireRequired)
        case .oneOf(let names):
            return try coerceUnionPosition(value, names: names, at: path, requireRequired: requireRequired)
        }
    }

    private func coerceReferencePosition(
        _ value: MockValue,
        target: String,
        at path: String,
        requireRequired: Bool
    ) throws -> MockValue {
        guard case .object = spec.schemas[target] else {
            // The $ref names a scalar alias — coerce against the aliased shape directly.
            guard let aliased = spec.schemas[target] else {
                throw error("Internal error: unknown schema '\(target)'", at: path)
            }
            return try coerce(value, to: aliased, at: path, requireRequired: requireRequired)
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
            return .object(
                try coerceRecord(fields, schemaName: target, at: path, requireRequired: requireRequired))
        default:
            throw error("Expected a reference or object for '\(target)', found \(value)", at: path)
        }
    }

    private func coerceUnionPosition(
        _ value: MockValue,
        names: [String],
        at path: String,
        requireRequired: Bool
    ) throws -> MockValue {
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
        case .object(let fields):
            // An embedded object is whichever variant it validates against, tried in declared
            // order. References inside it are only reported for the variant that wins.
            var failures: [String] = []
            for name in names {
                guard let variant = spec.aliasTarget(of: name), case .object = variant.node else { continue }
                var seen: [(typeName: String, id: String, path: String)] = []
                let attempt = SchemaCoercion(
                    spec: spec,
                    category: category,
                    sourceName: sourceName,
                    recordReference: { seen.append(($0, $1, $2)) }
                )
                do {
                    let coerced = try attempt.coerceRecord(
                        fields, schemaName: variant.name, at: path, requireRequired: requireRequired)
                    for reference in seen {
                        recordReference(reference.typeName, reference.id, reference.path)
                    }
                    return .object(coerced)
                } catch let mismatch as MockError {
                    failures.append("\(name): \(mismatch.message)")
                }
            }
            guard !failures.isEmpty else {
                throw error(
                    "Embedded objects cannot be used here: none of \(possible) is an object schema; "
                        + "use a qualified reference like 'Schema:id'",
                    at: path
                )
            }
            throw error(
                "This object matches none of the possible schemas here (\(possible)) — "
                    + failures.joined(separator: "; "),
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
