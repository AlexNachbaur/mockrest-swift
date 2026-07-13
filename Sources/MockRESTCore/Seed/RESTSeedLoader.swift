import MockCore

/// Validates a REST seed document (`version` / `data` / `resources`) and produces the initial
/// store contents.
///
/// With a spec, `components.schemas` are the type system and every record is validated against
/// its schema; without one (DSL-only mode), state is named resource collections and validation
/// is structural. Either way the whole document is checked before the server starts.
struct RESTSeedLoader {
    private let spec: RESTSpec?
    private let sourceName: String?
    private let idFieldBySchema: [String: String]
    private var data = StoreData()
    private let references = ReferenceBox()

    /// Collects references encountered during coercion so they can be checked after the whole
    /// document loads (forward references are legal in seeds).
    private final class ReferenceBox {
        var pending: [(typeName: String, id: String, path: String)] = []
    }

    /// The `resources:` declarations parsed from a raw seed document, before data loads.
    static func declaredResources(in document: MockValue, spec: RESTSpec?, sourceName: String?) throws
        -> [ResourceModel]
    {
        guard let sections = document.objectValue else {
            throw seedError("Seed document must be a mapping", at: "", sourceName: sourceName)
        }
        guard let section = sections["resources"] else { return [] }
        guard let entries = section.objectValue else {
            throw seedError(
                "'resources' must be a mapping of collection names to {schema, path, idField}",
                at: "resources",
                sourceName: sourceName
            )
        }
        var resources: [ResourceModel] = []
        for name in entries.keys.sorted() {
            let entry = entries[name] ?? .null
            let path = "resources.\(name)"
            guard entry.objectValue != nil else {
                throw seedError("Resource '\(name)' must be a mapping", at: path, sourceName: sourceName)
            }
            let schema = entry["schema"].stringValue ?? name
            if let spec {
                guard case .object = spec.schemas[schema] else {
                    let objectNames = spec.schemas.keys.filter {
                        if case .object = spec.schemas[$0] { return true }
                        return false
                    }
                    let clause = Suggestion.clause(for: schema, in: objectNames)
                    throw seedError(
                        "Resource '\(name)' names unknown object schema '\(schema)'.\(clause)",
                        at: "\(path).schema",
                        sourceName: sourceName
                    )
                }
            }
            resources.append(
                ResourceModel(
                    name: name,
                    schema: schema,
                    basePath: entry["path"].stringValue ?? "/\(name)",
                    idField: entry["idField"].stringValue ?? "id",
                    listEnvelope: nil
                )
            )
        }
        return resources
    }

    /// Loads, validates, and coerces a seed document into store data.
    static func load(
        document: MockValue,
        spec: RESTSpec?,
        resources: [ResourceModel],
        sourceName: String?
    ) throws -> StoreData {
        var idFields: [String: String] = [:]
        for resource in resources {
            idFields[resource.schema] = resource.idField
        }
        var loader = RESTSeedLoader(spec: spec, sourceName: sourceName, idFieldBySchema: idFields)
        return try loader.run(document: document)
    }

    private mutating func run(document: MockValue) throws -> StoreData {
        guard let sections = document.objectValue else {
            throw error("Seed document must be a mapping with 'version', 'data', and 'resources' sections", at: "")
        }
        let allowed = ["version", "data", "resources"]
        for key in sections.keys.sorted() where !allowed.contains(key) {
            throw error("Unknown top-level key '\(key)'.\(Suggestion.clause(for: key, in: allowed))", at: key)
        }
        guard let version = sections["version"] else {
            throw error("Seed document is missing 'version: 1'", at: "version")
        }
        guard version == .int(1) else {
            throw error("Unsupported seed format version \(version); this MockREST supports version 1", at: "version")
        }
        if let dataSection = sections["data"] {
            try loadDataSection(dataSection)
        }
        try resolvePendingReferences()
        return data
    }

    private mutating func loadDataSection(_ section: MockValue) throws {
        guard let types = section.objectValue else {
            throw error("'data' must be a mapping of schema (or resource) names to record lists", at: "data")
        }
        for typeName in types.keys.sorted() {
            if let spec {
                guard case .object = spec.schemas[typeName] else {
                    let objectNames = spec.schemas.keys.filter {
                        if case .object = spec.schemas[$0] { return true }
                        return false
                    }
                    let clause = Suggestion.clause(for: typeName, in: objectNames)
                    if spec.schemas[typeName] != nil {
                        throw error(
                            "'\(typeName)' is not an object schema; only object schemas can be seeded",
                            at: "data.\(typeName)"
                        )
                    }
                    throw error("Unknown schema '\(typeName)' under 'data'.\(clause)", at: "data.\(typeName)")
                }
            }
            guard let entries = types[typeName]?.listValue else {
                throw error("'data.\(typeName)' must be a list of records", at: "data.\(typeName)")
            }
            let idField = idFieldBySchema[typeName] ?? "id"
            for (index, entry) in entries.enumerated() {
                let path = "data.\(typeName)[\(index)]"
                guard let fields = entry.objectValue else {
                    throw error("Record must be a mapping of field names to values", at: path)
                }
                var coerced: [String: MockValue]
                if spec != nil {
                    coerced = try coercion().coerceRecord(fields, schemaName: typeName, at: path, idField: idField)
                } else {
                    coerced = fields
                }
                try insertRecord(&coerced, typeName: typeName, idField: idField, at: path)
            }
        }
    }

    /// Inserts a coerced record, keying it by its id field (coercing int ids to strings) and
    /// keeping the canonical internal `id` in sync for custom id fields.
    private mutating func insertRecord(
        _ fields: inout [String: MockValue],
        typeName: String,
        idField: String,
        at path: String
    ) throws {
        var id: String?
        switch fields[idField] {
        case .some(.string(let text)):
            id = text
        case .some(.int(let number)):
            id = String(number)
            fields[idField] = .string(id ?? "")
        case .none:
            id = nil
        default:
            throw error("'\(idField)' must be a string or integer id", at: "\(path).\(idField)")
        }
        if let id {
            guard data.record(type: typeName, id: id) == nil else {
                throw error("Duplicate id '\(id)' for '\(typeName)'", at: path)
            }
            fields["id"] = .string(id)
            data.insert(type: typeName, fields: fields)
        } else {
            let generated = data.insert(type: typeName, fields: fields)
            if idField != "id" {
                data.records[typeName]?[generated]?[idField] = .string(generated)
            }
        }
    }

    private func coercion() -> SchemaCoercion {
        let box = references
        return SchemaCoercion(
            spec: spec ?? RESTSpec(),
            category: .seed,
            sourceName: sourceName,
            recordReference: { typeName, id, path in
                box.pending.append((typeName, id, path))
            }
        )
    }

    private func resolvePendingReferences() throws {
        for reference in references.pending {
            guard data.record(type: reference.typeName, id: reference.id) != nil else {
                let known = data.order[reference.typeName] ?? []
                let clause = Suggestion.clause(for: reference.id, in: known)
                throw error(
                    "Dangling reference: no '\(reference.typeName)' record with id '\(reference.id)'.\(clause)",
                    at: reference.path
                )
            }
        }
    }

    private func error(_ message: String, at path: String) -> MockError {
        Self.seedError(message, at: path, sourceName: sourceName)
    }

    private static func seedError(_ message: String, at path: String, sourceName: String?) -> MockError {
        MockError(
            category: .seed,
            message: message,
            sourceName: sourceName,
            documentPath: path.isEmpty ? nil : path
        )
    }
}
