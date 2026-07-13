import MockCore

/// The response an endpoint handler returns.
///
/// Bodies are `MockValue` trees; `.reference` values are resolved against the state store — and
/// omitted schema fields filled by generators — on the way out.
public struct RESTResponse: Sendable {
    /// The HTTP status code.
    public var status: Int
    /// Extra response headers (e.g. `Location`). `Content-Type: application/json` is implied
    /// for responses with a body.
    public var headers: [(name: String, value: String)]
    /// The response body, or `nil` for an empty body.
    public var body: MockValue?

    /// Creates a response.
    public init(status: Int, headers: [(name: String, value: String)] = [], body: MockValue? = nil) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// `200 OK` with a JSON body.
    public static func ok(_ body: MockValue) -> RESTResponse {
        RESTResponse(status: 200, body: body)
    }

    /// `201 Created` with a JSON body and, optionally, a `Location` header.
    public static func created(_ body: MockValue, location: String? = nil) -> RESTResponse {
        RESTResponse(status: 201, headers: location.map { [("Location", $0)] } ?? [], body: body)
    }

    /// `204 No Content`.
    public static let noContent = RESTResponse(status: 204)

    /// `404 Not Found` with a generic error body.
    public static let notFound = RESTResponse.notFound("Not found")

    /// `404 Not Found` with a specific message.
    public static func notFound(_ message: String) -> RESTResponse {
        .errors(status: 404, [(message: message, path: nil)])
    }

    /// An arbitrary status with an optional JSON body.
    public static func status(_ code: Int, body: MockValue? = nil) -> RESTResponse {
        RESTResponse(status: code, body: body)
    }

    /// An error response in MockREST's diagnostic shape:
    /// `{"errors": [{"message": …, "path": …}]}`.
    public static func errors(status: Int, _ errors: [(message: String, path: String?)]) -> RESTResponse {
        let list = errors.map { error -> MockValue in
            var entry: MockValue = ["message": .string(error.message)]
            if let path = error.path {
                entry["path"] = .string(path)
            }
            return entry
        }
        return RESTResponse(status: status, body: ["errors": .list(list)])
    }
}
