import MockCore

/// The normalized internal model an OpenAPI 3.0/3.1 document is ingested into. Both versions
/// reduce to this one shape so the rest of the engine never cares which dialect it came from.
struct RESTSpec: Sendable {
    /// Named schemas from `components.schemas`.
    var schemas: [String: SchemaNode] = [:]
    /// Schema-level `example` values, used to seed state when no explicit seed data exists.
    var schemaExamples: [String: MockValue] = [:]
    /// Named schemas that are themselves nullable (3.1 `type: [T, "null"]` or a `oneOf` with a
    /// null variant), so `$ref`s to them accept explicit nulls.
    var nullableSchemas: Set<String> = []
    /// Every operation under `paths`.
    var operations: [SpecOperation] = []

    /// The named schema, or `nil`.
    func schema(named name: String) -> SchemaNode? {
        schemas[name]
    }

    /// The properties of a named object schema, or `nil` when the name is unknown or not an
    /// object.
    func objectProperties(of name: String) -> [String: SchemaNode.Property]? {
        guard case .object(let properties, _) = schemas[name] else { return nil }
        return properties
    }
}

/// A normalized schema shape.
indirect enum SchemaNode: Sendable, Hashable {
    /// A string, optionally with a `format` hint and/or an `enum` member list.
    case string(format: String?, enumValues: [String]?)
    /// An integer.
    case integer
    /// A floating-point number.
    case number
    /// A boolean.
    case boolean
    /// An array of a single element shape.
    case array(of: SchemaNode)
    /// An inline object with named properties.
    case object(properties: [String: Property], required: Set<String>)
    /// A `$ref` to a named schema in `components.schemas`.
    case reference(String)
    /// A `oneOf`/`anyOf` union of named schemas; values in this position need qualified
    /// `Schema:id` references so the concrete type is known.
    case oneOf([String])
    /// An untyped/unconstrained position; values pass through as authored.
    case any

    /// One property of an object schema.
    struct Property: Sendable, Hashable {
        var node: SchemaNode
        var nullable: Bool
    }

    /// A short human-readable description for diagnostics.
    var typeDescription: String {
        switch self {
        case .string(_, let enumValues):
            return enumValues == nil ? "string" : "enum"
        case .integer: return "integer"
        case .number: return "number"
        case .boolean: return "boolean"
        case .array: return "array"
        case .object: return "object"
        case .reference(let name): return name
        case .oneOf(let names): return "one of \(names.joined(separator: "/"))"
        case .any: return "any"
        }
    }
}

/// One `paths` operation, normalized.
struct SpecOperation: Sendable {
    var method: String
    var pattern: RoutePattern
    /// Query/path/header parameters declared on the operation (path-level ones merged in).
    var parameters: [SpecParameter]
    /// The `application/json` request body schema, when declared.
    var requestBody: SchemaNode?
    var requestBodyRequired: Bool
    /// The success status served by the auto-wired handler (the lowest declared 2xx, else 200).
    var successStatus: Int
    /// The success response's `application/json` schema, when declared.
    var responseSchema: SchemaNode?
    /// The success response's `example`, when present; it wins over schema synthesis.
    var responseExample: MockValue?
}

/// One declared operation parameter.
struct SpecParameter: Sendable {
    var name: String
    /// `"path"`, `"query"`, or `"header"`.
    var location: String
    var required: Bool
}

/// A resource collection: what wires records in the store to CRUD routes.
struct ResourceModel: Sendable {
    var name: String
    var schema: String
    var basePath: String
    var idField: String
    /// When the spec's list response is an envelope (`{data: [Item], total: …}`), how to
    /// synthesize it: the array property's name and the sibling properties.
    var listEnvelope: EnvelopeModel?
    /// The path-parameter name of the item route (`/users/{userId}` → `"userId"`); CRUD
    /// handlers read the id from it.
    var itemParamName: String = "id"
    /// Whether this resource was inferred from the spec (inferred collections only get the
    /// operations the spec declares; explicit ones get the full conventional set).
    var inferred: Bool = false
}

/// A detected list-response envelope.
struct EnvelopeModel: Sendable {
    var itemsProperty: String
    var extraProperties: [String: SchemaNode.Property]
}
