import Foundation
import MockCore

/// A parsed path template like `/users/{id}`, matchable against concrete request paths.
///
/// A parameter usually fills a whole path segment, but it may also share one with literal text
/// (`/files/{name}.json`, `/users/{id}:activate`, `/{year}-{month}`). Two parameters in the
/// same segment need literal text between them — `/{a}{b}` has no way to tell where one value
/// ends and the next begins, so it is rejected.
public struct RoutePattern: Sendable, Hashable, CustomStringConvertible {
    enum Segment: Hashable, Sendable {
        case literal(String)
        case parameter(String)
        /// Literal text and parameters sharing one path segment (`{name}.json`).
        case mixed([Piece])
    }

    /// One piece of a ``Segment/mixed(_:)`` segment.
    enum Piece: Hashable, Sendable {
        case literal(String)
        case parameter(String)
    }

    let segments: [Segment]
    /// The template this pattern was parsed from, normalized without a trailing slash.
    public let template: String

    /// Parses a template. `{…}` marks a parameter; anything else is literal.
    ///
    /// - Throws: A configuration `MockError` for an empty template, a template not
    ///   starting with `/`, an empty or unclosed `{parameter}`, two parameters with nothing
    ///   between them, or a duplicate parameter name.
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
            if part.isEmpty {
                guard trimmed == "/" else {
                    throw MockError(
                        category: .configuration,
                        message: "Route template '\(template)' has an empty path segment"
                    )
                }
                continue
            }
            let pieces = try Self.pieces(of: part, template: template)
            for case .parameter(let name) in pieces {
                guard seenParameters.insert(name).inserted else {
                    throw MockError(
                        category: .configuration,
                        message: "Route template '\(template)' declares parameter '{\(name)}' more than once"
                    )
                }
            }
            switch (pieces.count, pieces.first) {
            case (1, .some(.literal(let text))):
                segments.append(.literal(text))
            case (1, .some(.parameter(let name))):
                segments.append(.parameter(name))
            default:
                segments.append(.mixed(pieces))
            }
        }
        self.segments = segments
        self.template = trimmed
    }

    /// Splits one path segment into its literal and `{parameter}` pieces.
    private static func pieces(of part: String, template: String) throws -> [Piece] {
        let malformed = MockError(
            category: .configuration,
            message: "Route template '\(template)' has a malformed parameter segment '\(part)'"
        )
        var pieces: [Piece] = []
        var literal = ""
        var rest = Substring(part)
        while let character = rest.first {
            switch character {
            case "{":
                guard let close = rest.firstIndex(of: "}") else { throw malformed }
                let name = String(rest[rest.index(after: rest.startIndex)..<close])
                guard !name.isEmpty, !name.contains("{") else { throw malformed }
                if !literal.isEmpty {
                    pieces.append(.literal(literal))
                    literal = ""
                } else if case .parameter(let previous) = pieces.last {
                    throw MockError(
                        category: .configuration,
                        message: "Route template '\(template)' puts parameters '{\(previous)}' and '{\(name)}' "
                            + "next to each other in segment '\(part)'; separate them with literal text so "
                            + "each value has a boundary"
                    )
                }
                pieces.append(.parameter(name))
                rest = rest[rest.index(after: close)...]
            case "}":
                throw malformed
            default:
                literal.append(character)
                rest = rest.dropFirst()
            }
        }
        if !literal.isEmpty {
            pieces.append(.literal(literal))
        }
        return pieces
    }

    /// The declared parameter names, in template order.
    public var parameterNames: [String] {
        segments.flatMap { segment -> [String] in
            switch segment {
            case .literal:
                return []
            case .parameter(let name):
                return [name]
            case .mixed(let pieces):
                return pieces.compactMap { piece -> String? in
                    if case .parameter(let name) = piece { return name }
                    return nil
                }
            }
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
            case .mixed(let pieces):
                guard Self.match(pieces[...], against: part[...], into: &extracted) else { return nil }
            }
        }
        return extracted
    }

    /// Matches the pieces of a mixed segment against one concrete path segment. A parameter
    /// takes as much text as it can while the rest of the segment still matches, so
    /// `{name}.json` against `archive.tar.json` yields `archive.tar`.
    private static func match(
        _ pieces: ArraySlice<Piece>,
        against text: Substring,
        into extracted: inout [String: String]
    ) -> Bool {
        guard let piece = pieces.first else { return text.isEmpty }
        let remaining = pieces.dropFirst()
        switch piece {
        case .literal(let literal):
            guard text.hasPrefix(literal) else { return false }
            return match(remaining, against: text.dropFirst(literal.count), into: &extracted)
        case .parameter(let name):
            guard let next = remaining.first else {
                guard !text.isEmpty, let decoded = String(text).removingPercentEncoding else { return false }
                extracted[name] = decoded
                return true
            }
            // Parsing guarantees a literal follows a parameter that is not last.
            guard case .literal(let boundary) = next else { return false }
            var searchEnd = text.endIndex
            while let range = text[..<searchEnd].range(of: boundary, options: .backwards) {
                let value = text[..<range.lowerBound]
                if !value.isEmpty, let decoded = String(value).removingPercentEncoding {
                    var attempt = extracted
                    attempt[name] = decoded
                    if match(remaining.dropFirst(), against: text[range.upperBound...], into: &attempt) {
                        extracted = attempt
                        return true
                    }
                }
                searchEnd = text.index(before: range.upperBound)
            }
            return false
        }
    }

    /// The template with parameter names erased (`/users/{}`): two templates with the same
    /// shape match exactly the same paths, whatever their parameters are called.
    var shape: String {
        guard !segments.isEmpty else { return "/" }
        return segments.map { segment -> String in
            switch segment {
            case .literal(let text):
                return "/" + text
            case .parameter:
                return "/{}"
            case .mixed(let pieces):
                return "/"
                    + pieces.map { piece -> String in
                        if case .literal(let text) = piece { return text }
                        return "{}"
                    }.joined()
            }
        }.joined()
    }

    /// Orders patterns by specificity: literal segments beat partly-literal ones, which beat
    /// whole-segment parameters, position-by-position — so `/users/me` wins over
    /// `/users/{id}`, and `/files/{name}.json` wins over `/files/{id}`. Deterministic and
    /// documented.
    static func moreSpecific(_ lhs: RoutePattern, _ rhs: RoutePattern) -> Bool {
        func rank(_ segment: Segment) -> Int {
            switch segment {
            case .literal: return 0
            case .mixed: return 1
            case .parameter: return 2
            }
        }
        for (left, right) in zip(lhs.segments, rhs.segments) where rank(left) != rank(right) {
            return rank(left) < rank(right)
        }
        if lhs.segments.count != rhs.segments.count {
            return lhs.segments.count > rhs.segments.count
        }
        return lhs.template < rhs.template
    }

    /// The normalized template, e.g. `/users/{id}`.
    public var description: String {
        template
    }
}
