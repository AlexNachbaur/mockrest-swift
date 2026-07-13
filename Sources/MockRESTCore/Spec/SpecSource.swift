import Foundation
import MockCore

/// Where an OpenAPI spec comes from: a file on disk or an inline string.
public struct SpecSource: Sendable {
    enum Kind: Sendable {
        case file(String)
        case yaml(String)
        case json(String)
    }

    let kind: Kind

    /// Loads the spec from a file. `.json` files parse as JSON; anything else parses as YAML
    /// (of which JSON is a subset).
    public static func file(_ path: String) -> SpecSource {
        SpecSource(kind: .file(path))
    }

    /// An inline YAML spec.
    public static func yaml(_ text: String) -> SpecSource {
        SpecSource(kind: .yaml(text))
    }

    /// An inline JSON spec.
    public static func json(_ text: String) -> SpecSource {
        SpecSource(kind: .json(text))
    }

    /// The name used for this source in diagnostics.
    var sourceName: String? {
        switch kind {
        case .file(let path): return path
        case .yaml: return "inline YAML spec"
        case .json: return "inline JSON spec"
        }
    }

    /// Reads and parses the raw document value (no OpenAPI validation yet).
    func rawDocument() throws -> MockValue {
        switch kind {
        case .yaml(let text):
            return try YAMLDecoding.decode(text, sourceName: sourceName, category: .schema)
        case .json(let text):
            return try Self.decodeJSON(text, sourceName: sourceName)
        case .file(let path):
            let text: String
            do {
                text = try String(contentsOfFile: path, encoding: .utf8)
            } catch {
                throw MockError(
                    category: .schema,
                    message: "Cannot read spec file: \(error.localizedDescription)",
                    sourceName: path
                )
            }
            if path.lowercased().hasSuffix(".json") {
                return try Self.decodeJSON(text, sourceName: path)
            }
            return try YAMLDecoding.decode(text, sourceName: path, category: .schema)
        }
    }

    private static func decodeJSON(_ text: String, sourceName: String?) throws -> MockValue {
        do {
            return try MockValue.fromJSONString(text)
        } catch {
            throw MockError(
                category: .schema,
                message: "Spec document is not valid JSON: \(error.localizedDescription)",
                sourceName: sourceName
            )
        }
    }
}
