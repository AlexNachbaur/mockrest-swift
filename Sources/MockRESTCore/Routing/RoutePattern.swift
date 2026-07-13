import MockCore

/// A parsed path template like `/users/{id}`, matchable against concrete request paths.
public struct RoutePattern: Sendable, Hashable, CustomStringConvertible {
    enum Segment: Hashable, Sendable {
        case literal(String)
        case parameter(String)
    }

    let segments: [Segment]
    /// The template this pattern was parsed from, normalized without a trailing slash.
    public let template: String

    /// Parses a template. Segments wrapped in `{…}` are parameters; anything else is literal.
    ///
    /// - Throws: A configuration `MockError` for an empty template, a template not
    ///   starting with `/`, an empty or unclosed `{parameter}`, or a duplicate parameter name.
    public init(parsing template: String) throws {
        guard template.hasPrefix("/") else {
            throw MockError(
                category: .configuration,
                message: "Route template '\(template)' must start with '/'"
            )
        }
        let trimmed = template.count > 1 && template.hasSuffix("/") ? String(template.dropLast()) : template
        var segments: [Segment] = []
        var seenParameters: Set<String> = []
        for raw in trimmed.split(separator: "/", omittingEmptySubsequences: false).dropFirst() {
            let part = String(raw)
            if part.hasPrefix("{") || part.hasSuffix("}") {
                guard part.hasPrefix("{"), part.hasSuffix("}"), part.count > 2 else {
                    throw MockError(
                        category: .configuration,
                        message: "Route template '\(template)' has a malformed parameter segment '\(part)'"
                    )
                }
                let name = String(part.dropFirst().dropLast())
                guard seenParameters.insert(name).inserted else {
                    throw MockError(
                        category: .configuration,
                        message: "Route template '\(template)' declares parameter '{\(name)}' more than once"
                    )
                }
                segments.append(.parameter(name))
            } else if part.isEmpty, trimmed != "/" {
                throw MockError(
                    category: .configuration,
                    message: "Route template '\(template)' has an empty path segment"
                )
            } else if !part.isEmpty {
                segments.append(.literal(part))
            }
        }
        self.segments = segments
        self.template = trimmed
    }

    /// The declared parameter names, in template order.
    public var parameterNames: [String] {
        segments.compactMap {
            if case .parameter(let name) = $0 { return name }
            return nil
        }
    }

    /// Matches a concrete path, returning the extracted parameter values, or `nil`.
    func match(_ path: String) -> [String: String]? {
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(String.init)
        let concrete = parts == [""] ? [] : parts
        guard concrete.count == segments.count else { return nil }
        var extracted: [String: String] = [:]
        for (segment, part) in zip(segments, concrete) {
            switch segment {
            case .literal(let literal):
                guard literal == part else { return nil }
            case .parameter(let name):
                guard !part.isEmpty, let decoded = part.removingPercentEncoding else { return nil }
                extracted[name] = decoded
            }
        }
        return extracted
    }

    /// Orders patterns by specificity: literal segments beat parameters position-by-position,
    /// so `/users/me` wins over `/users/{id}`. Deterministic and documented.
    static func moreSpecific(_ lhs: RoutePattern, _ rhs: RoutePattern) -> Bool {
        for (left, right) in zip(lhs.segments, rhs.segments) {
            switch (left, right) {
            case (.literal, .parameter):
                return true
            case (.parameter, .literal):
                return false
            default:
                continue
            }
        }
        if lhs.segments.count != rhs.segments.count {
            return lhs.segments.count > rhs.segments.count
        }
        return lhs.template < rhs.template
    }

    public var description: String {
        template
    }
}
