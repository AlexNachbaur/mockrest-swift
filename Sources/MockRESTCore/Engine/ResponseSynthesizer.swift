import MockCore

/// Builds response bodies: stored fields pass through, omitted schema fields are filled by
/// generators (stable per record + field), and `.reference` values embed the referenced record.
struct ResponseSynthesizer: Sendable {
    let spec: RESTSpec?
    let generators: GeneratorRegistry
    /// DSL-only mode has no schema to say which fields a record is missing, so the explicit
    /// generator bindings do: record type → the field names bound for it.
    var boundFields: [String: [String]] = [:]
    /// How deep reference embedding recurses before falling back to a `Schema:id` string —
    /// bounds cyclic data (a `Cart` whose `owner`'s `carts` contain the cart …).
    static let maxDepth = 4

    // MARK: - Schema-driven (spec mode)

    /// Serializes a stored record against its named schema: every schema property appears,
    /// stored values win, omitted values are generated, pinned nulls stay null. Stored fields
    /// the schema does not declare (written by a handler, or by a sibling protocol mock sharing
    /// the store) pass through rather than vanish.
    ///
    /// Without a schema for the type (DSL-only mode) the record passes through as stored, plus
    /// any field with an explicit generator binding that the record omits.
    func serializeRecord(
        _ record: MockValue,
        schemaName: String,
        data: StoreData,
        depth: Int = maxDepth
    ) -> MockValue {
        guard let fields = record.objectValue else {
            return resolveReferences(record, data: data, depth: depth)
        }
        let recordID = fields["id"]?.stringValue
        if let spec, case .object(let properties, _, let additional) = spec.schemas[schemaName] {
            return serialize(
                fields,
                shape: (properties, additional),
                schemaName: schemaName,
                recordID: recordID,
                isStoredRecord: true,
                data: data,
                depth: depth
            )
        }
        var result = fields.mapValues { resolveReferences($0, data: data, depth: depth) }
        for name in boundFields[schemaName] ?? [] where result[name] == nil {
            result[name] = generators.value(
                typeName: schemaName, recordID: recordID, field: name, scalarTypeName: "String")
        }
        return .object(result)
    }

    /// Renders a stored value into its schema position, embedding references.
    private func render(_ value: MockValue, as node: SchemaNode, data: StoreData, depth: Int) -> MockValue {
        switch (value, node) {
        case (.reference(let typeName, let id), _):
            return embed(typeName: typeName, id: id, data: data, depth: depth)
        case (.list(let items), .array(let element)):
            return .list(items.map { render($0, as: element, data: data, depth: depth) })
        case (.object(let fields), .reference(let target)):
            // An anonymous embedded value object: serialize against the target schema so its
            // omitted fields generate too (with no record id — it is not a stored record).
            guard let spec, case .object(let properties, _, let additional) = spec.schemas[target] else {
                return resolveReferences(value, data: data, depth: depth)
            }
            return serialize(
                fields,
                shape: (properties, additional),
                schemaName: target,
                recordID: nil,
                isStoredRecord: false,
                data: data,
                depth: depth
            )
        case (.object(let fields), .object(let properties, _, let additional)):
            var result: [String: MockValue] = [:]
            for (name, fieldValue) in fields {
                let propertyNode = properties[name]?.node ?? additional ?? .any
                result[name] = render(fieldValue, as: propertyNode, data: data, depth: depth)
            }
            return .object(result)
        default:
            return resolveReferences(value, data: data, depth: depth)
        }
    }

    /// Serializes an object's fields against an object schema: declared properties are
    /// rendered or generated, undeclared stored fields pass through.
    private func serialize(
        _ fields: [String: MockValue],
        shape: (properties: [String: SchemaNode.Property], additional: SchemaNode?),
        schemaName: String,
        recordID: String?,
        isStoredRecord: Bool,
        data: StoreData,
        depth: Int
    ) -> MockValue {
        var result: [String: MockValue] = [:]
        for (name, property) in shape.properties {
            if let stored = fields[name] {
                result[name] = render(stored, as: property.node, data: data, depth: depth)
            } else {
                result[name] = generate(
                    property: property,
                    typeName: schemaName,
                    recordID: recordID,
                    fieldName: name,
                    data: data
                )
            }
        }
        for (name, stored) in fields where shape.properties[name] == nil {
            // The store keys every record by a canonical `id`; when the schema names its id
            // field something else, that copy is a mock internal, not part of the API.
            if isStoredRecord, name == "id" {
                continue
            }
            result[name] = render(stored, as: shape.additional ?? .any, data: data, depth: depth)
        }
        return .object(result)
    }

    /// Embeds a referenced record, or falls back to its `Schema:id` string at the depth limit
    /// (or for a dangling reference created mid-test).
    private func embed(typeName: String, id: String, data: StoreData, depth: Int) -> MockValue {
        guard depth > 0, let record = data.record(type: typeName, id: id) else {
            return .string("\(typeName):\(id)")
        }
        return serializeRecord(record, schemaName: typeName, data: data, depth: depth - 1)
    }

    /// A generated value for an omitted schema field. Pure function of (server seed, type,
    /// record id, field), so it is stable across reads.
    private func generate(
        property: SchemaNode.Property,
        typeName: String,
        recordID: String?,
        fieldName: String,
        data: StoreData
    ) -> MockValue {
        switch property.node {
        case .string(_, .some(let enumValues)):
            return generators.enumValue(typeName: typeName, recordID: recordID, field: fieldName, cases: enumValues)
        case .array:
            // Omitted collections stay empty — inventing relations would surprise more than
            // it helps.
            return .list([])
        case .reference(let name):
            // A `$ref` to a scalar, enum, or array schema generates like the shape it names.
            // Only a `$ref` to an object schema is a record reference, and an omitted one
            // stays null: there is no record to point at.
            guard let target = spec?.aliasTarget(of: name) else { return .null }
            if case .object = target.node {
                return .null
            }
            return generate(
                property: SchemaNode.Property(node: target.node, nullable: property.nullable),
                typeName: typeName,
                recordID: recordID,
                fieldName: fieldName,
                data: data
            )
        case .oneOf:
            return .null
        case .object(let properties, _, _):
            var result: [String: MockValue] = [:]
            for (name, nested) in properties {
                result[name] = generate(
                    property: nested,
                    typeName: typeName,
                    recordID: recordID,
                    fieldName: "\(fieldName).\(name)",
                    data: data
                )
            }
            return .object(result)
        default:
            return generators.value(
                typeName: typeName,
                recordID: recordID,
                field: fieldName,
                scalarTypeName: Self.scalarTypeName(for: property.node)
            )
        }
    }

    /// Synthesizes a response body for a non-resource spec operation (no stored records to
    /// serve): references pick the first stored record of that schema or generate a synthetic
    /// one; scalars generate stably, keyed by the operation.
    func synthesize(node: SchemaNode, pseudoType: String, fieldName: String, data: StoreData, depth: Int = maxDepth)
        -> MockValue
    {
        switch node {
        case .reference(let name):
            let target = spec?.aliasTarget(of: name)
            let typeName = target?.name ?? name
            if let firstID = data.order[typeName]?.first, let record = data.record(type: typeName, id: firstID) {
                return serializeRecord(record, schemaName: typeName, data: data, depth: depth)
            }
            guard let target, depth > 0 else { return .null }
            guard case .object(let properties, _, _) = target.node else {
                // A `$ref` to a scalar, enum, or array schema: synthesize the shape it names.
                return synthesize(
                    node: target.node, pseudoType: pseudoType, fieldName: fieldName, data: data, depth: depth)
            }
            var result: [String: MockValue] = [:]
            for (propertyName, property) in properties {
                result[propertyName] = generate(
                    property: property,
                    typeName: typeName,
                    recordID: nil,
                    fieldName: propertyName,
                    data: data
                )
            }
            return .object(result)
        case .oneOf(let names):
            guard let first = names.first else { return .null }
            return synthesize(
                node: .reference(first), pseudoType: pseudoType, fieldName: fieldName, data: data,
                depth: depth)
        case .array(let element):
            return .list([
                synthesize(
                    node: element, pseudoType: pseudoType, fieldName: "\(fieldName)[0]", data: data,
                    depth: depth),
                synthesize(
                    node: element, pseudoType: pseudoType, fieldName: "\(fieldName)[1]", data: data,
                    depth: depth),
            ])
        case .object(let properties, _, _):
            var result: [String: MockValue] = [:]
            for (name, property) in properties {
                switch property.node {
                case .string(_, .some(let enumValues)):
                    result[name] = generators.enumValue(
                        typeName: pseudoType, recordID: nil, field: name, cases: enumValues)
                case .array, .reference, .oneOf, .object:
                    result[name] = synthesize(
                        node: property.node, pseudoType: pseudoType, fieldName: name, data: data, depth: depth)
                default:
                    result[name] = generators.value(
                        typeName: pseudoType,
                        recordID: nil,
                        field: name,
                        scalarTypeName: Self.scalarTypeName(for: property.node)
                    )
                }
            }
            return .object(result)
        case .string(_, .some(let enumValues)):
            return generators.enumValue(typeName: pseudoType, recordID: nil, field: fieldName, cases: enumValues)
        default:
            return generators.value(
                typeName: pseudoType,
                recordID: nil,
                field: fieldName,
                scalarTypeName: Self.scalarTypeName(for: node)
            )
        }
    }

    // MARK: - Value-driven (DSL mode and handler-returned bodies)

    /// Resolves `.reference` values inside an arbitrary value tree by embedding the referenced
    /// records; everything else passes through as authored.
    func resolveReferences(_ value: MockValue, data: StoreData, depth: Int = maxDepth) -> MockValue {
        switch value {
        case .reference(let typeName, let id):
            return embed(typeName: typeName, id: id, data: data, depth: depth)
        case .list(let items):
            return .list(items.map { resolveReferences($0, data: data, depth: depth) })
        case .object(let fields):
            return .object(fields.mapValues { resolveReferences($0, data: data, depth: depth) })
        default:
            return value
        }
    }

    /// Maps a schema node to the scalar-type vocabulary the generator registry infers from
    /// (`ID`, `Int`, `Float`, `Boolean`, `String`, or a custom hint like `DateTime`).
    static func scalarTypeName(for node: SchemaNode) -> String {
        switch node {
        case .integer: return "Int"
        case .number: return "Float"
        case .boolean: return "Boolean"
        case .string(let format, _):
            switch format {
            case "uuid": return "ID"
            case "date-time", "date": return "DateTime"
            default: return "String"
            }
        default:
            return "String"
        }
    }
}
