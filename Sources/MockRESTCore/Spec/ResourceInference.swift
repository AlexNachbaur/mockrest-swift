import MockCore

/// Infers resource collections from a spec's paths, so conventional APIs get auto-CRUD with no
/// `resources:` block: a `/things` + `/things/{param}` path pair whose operations resolve to a
/// named object schema (with an id property) becomes a collection.
struct ResourceInference {
    static func infer(from spec: RESTSpec) -> [ResourceModel] {
        var byBasePath: [String: [SpecOperation]] = [:]
        for operation in spec.operations {
            let segments = operation.pattern.segments
            if segments.count >= 1, case .parameter = segments[segments.count - 1] {
                let base =
                    "/"
                    + segments.dropLast().compactMap { segment -> String? in
                        if case .literal(let text) = segment { return text }
                        return nil
                    }.joined(separator: "/")
                // Only infer flat collections: /things/{id}, not /a/{x}/b/{y}.
                guard segments.count == 2 else { continue }
                byBasePath[base, default: []].append(operation)
            } else if segments.allSatisfy({
                guard case .literal = $0 else { return false }
                return true
            }) {
                byBasePath[operation.pattern.template, default: []].append(operation)
            }
        }
        var resources: [ResourceModel] = []
        for (basePath, operations) in byBasePath.sorted(by: { $0.key < $1.key }) {
            guard basePath != "/", let name = basePath.split(separator: "/").last.map(String.init) else {
                continue
            }
            guard let schemaName = schemaName(for: operations, spec: spec) else { continue }
            guard let properties = spec.objectProperties(of: schemaName), properties["id"] != nil else {
                continue
            }
            let itemParamName = operations.compactMap { operation -> String? in
                operation.pattern.parameterNames.first
            }.first
            resources.append(
                ResourceModel(
                    name: name,
                    schema: schemaName,
                    basePath: basePath,
                    idField: "id",
                    listEnvelope: envelope(for: operations, itemSchema: schemaName, spec: spec),
                    itemParamName: itemParamName ?? "id",
                    inferred: true
                )
            )
        }
        return resources
    }

    /// The item schema the operations agree on: a `$ref` from the item GET/POST response, or
    /// the element of the list GET's array/envelope response.
    private static func schemaName(for operations: [SpecOperation], spec: RESTSpec) -> String? {
        for operation in operations {
            guard let response = operation.responseSchema else { continue }
            switch response {
            case .reference(let name):
                if case .object = spec.schemas[name] { return name }
            case .array(of: .reference(let name)):
                if case .object = spec.schemas[name] { return name }
            case .object(let properties, _):
                // An envelope: exactly one array-of-ref property identifies the item schema.
                let arrayRefs = properties.compactMap { _, property -> String? in
                    if case .array(of: .reference(let name)) = property.node { return name }
                    return nil
                }
                if arrayRefs.count == 1 { return arrayRefs[0] }
            default:
                continue
            }
        }
        return nil
    }

    /// Detects an envelope shape on the collection's list response.
    private static func envelope(
        for operations: [SpecOperation],
        itemSchema: String,
        spec: RESTSpec
    ) -> EnvelopeModel? {
        for operation in operations where operation.method == "GET" {
            // The list GET is the one on the collection path itself (no trailing parameter).
            guard case .literal = operation.pattern.segments.last else { continue }
            guard case .object(let properties, _) = operation.responseSchema else { continue }
            let arrayProperties = properties.filter {
                if case .array(of: .reference(itemSchema)) = $0.value.node { return true }
                return false
            }
            guard arrayProperties.count == 1, let items = arrayProperties.first else { continue }
            var extras = properties
            extras[items.key] = nil
            return EnvelopeModel(itemsProperty: items.key, extraProperties: extras)
        }
        return nil
    }
}
