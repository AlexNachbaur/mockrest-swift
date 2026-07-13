import MockCore

/// The REST view of an incoming request, handed to endpoint handlers.
public struct RESTRequest: Sendable {
    /// The HTTP method, uppercased (`"GET"`, `"POST"`, …).
    public let method: String
    /// The path, without the query string.
    public let path: String
    /// The decoded query parameters, in wire order.
    public let query: [(name: String, value: String)]
    /// All request headers, in wire order. Use ``header(_:)`` for case-insensitive lookup.
    public let headers: [(name: String, value: String)]
    /// The JSON request body as a value tree; `.null` when the request had no body.
    public let body: MockValue
    /// Values extracted from the matched route's path template (`/users/{id}` → `["id": …]`).
    public let pathParams: [String: String]

    /// Creates a request.
    public init(
        method: String,
        path: String,
        query: [(name: String, value: String)] = [],
        headers: [(name: String, value: String)] = [],
        body: MockValue = .null,
        pathParams: [String: String] = [:]
    ) {
        self.method = method.uppercased()
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
        self.pathParams = pathParams
    }

    /// The value of a path parameter from the matched route template.
    ///
    /// Returns `""` for a parameter the template does not declare — route validation at startup
    /// makes that a programmer error, not a runtime surprise.
    public func pathParam(_ name: String) -> String {
        pathParams[name] ?? ""
    }

    /// The first value of the named query parameter, or `nil`.
    public func queryValue(_ name: String) -> String? {
        query.first { $0.name == name }?.value
    }

    /// The first value of the named header, matched case-insensitively.
    public func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// A copy of this request carrying the given extracted path parameters.
    func with(pathParams: [String: String]) -> RESTRequest {
        RESTRequest(
            method: method,
            path: path,
            query: query,
            headers: headers,
            body: body,
            pathParams: pathParams
        )
    }
}
